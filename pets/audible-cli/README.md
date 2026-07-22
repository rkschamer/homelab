# Audible CLI Sync LXC

Downloads purchased Audible titles with [audible-rs](https://github.com/mkb79/audible-rs)
directly onto an NFS-mounted NAS share. Runs as a plain Alpine LXC **pet** on Proxmox —
deliberately not managed by Terraform/Flux. This document is the runbook to rebuild it
from scratch.

## Why not in the cluster?

audible-rs is automatable (`library sync`, `download --missing`), but running it as a
Kubernetes CronJob would require a self-built container image, a PV for mutable auth
state (token refresh rewrites the auth file), and an NFS mount — too much machinery for
a job that downloads a few files a month. A small LXC with cron does the same thing.

## Container

Created manually on the Proxmox host:

```sh
pveam update
pveam available --section system | grep alpine   # pick newest template
pveam download local <alpine-template>.tar.xz

pct create 152 local:vztmpl/<alpine-template>.tar.xz \
  --hostname audible \
  --unprivileged 1 \
  --cores 1 --memory 512 --swap 0 \
  --rootfs <storage>:8 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --onboot 1 --ostype alpine
pct start 152
pct exec 152 -- passwd
```

- **Bridge:** `vmbr0` (management/home LAN) — needs internet and NAS access.
- **Disk:** 8 GB — OS only. Books are written directly to the NAS via the NFS mount
  below; the container never holds the library.

## NFS mount (library directory)

The container is **unprivileged**, so it cannot mount NFS itself. Mount the share on
the **Proxmox host** and bind-mount it into the container:

```sh
# On the Proxmox host
mkdir -p /media/nas/audiobooks
echo '<nas-ip>:/<audiobooks-export> /media/nas/audiobooks nfs rw,hard 0 0' >> /etc/fstab
mount /media/nas/audiobooks

pct set 152 -mp0 /media/nas/audiobooks,mp=/data/audiobooks
```

**UID mapping caveat:** root inside the unprivileged container is UID 100000 on the
host. The NAS export must allow that UID to write — either map all clients to a NAS
user (`all_squash` + `anonuid` on the export) or make the target directory
world-writable for the mapped range. Verify with `touch /data/audiobooks/test` from
inside the container before setting up cron.

On Synology, the NFS rule (Control Panel → Shared Folder → Edit → NFS Permissions) is:
client IP = Proxmox host (192.168.123.8, the actual NFS client — not the container),
Privilege = Read/Write, **Squash = "Map all users to admin"** (root-only squash options
don't catch UID 100000), Security = sys, async enabled. Files on the NAS will be owned
by `admin`.

## Install (inside the container)

```sh
apk add ffmpeg curl openssh    # ffmpeg >= 4.4 decrypts .aaxc -> .m4b
rc-update add sshd && rc-service sshd start   # optional

cd /tmp
curl -LO https://github.com/mkb79/audible-rs/releases/download/v0.1.0-alpha.6/audible-0.1.0-alpha.6-x86_64-unknown-linux-musl.tar.gz
tar xzf audible-0.1.0-alpha.6-x86_64-unknown-linux-musl.tar.gz
mv audible /usr/local/bin/ && audible --version
```

The Linux release binaries are static musl builds, so they run on Alpine natively with
no extra runtime dependencies. Pin the version; the project is **alpha** and CLI flags
may change between releases — upgrade deliberately, not automatically.

## Auth (one-time, interactive)

Use the external-browser login flow: the CLI prints a URL, open it on a machine with a
browser, log in, paste the redirect URL back. See `audible auth --help` for the exact
subcommand. The auth file is rewritten on token refresh — it is mutable state, so after
a container rebuild the login must be redone (or auth file + passphrase restored from
backup).

**Auth file encryption:** enabled (the default, Argon2id + XChaCha20-Poly1305). Cron
still works because the passphrase is supplied non-interactively:

- Passphrase is stored in **Vaultwarden** (same convention as the sealed-secrets key).
- `password_source = "file"`: the passphrase lives in `/root/.config/audible/passwords`
  (the default `<config_dir>/passwords`), keyed by account name. Set both up in one go
  with `audible account password source <account> file`. Alternative: export
  `AUDIBLE_AUTH_PASSWORD` (or `AUDIBLE_AUTH_PASSWORD_<ACCOUNT>`) in the sync script.
  `keyring` does not work headless (needs a desktop secret service).
- Honest threat model: passphrase and ciphertext sit on the same disk, so encryption
  does not protect against container compromise. It protects the accidental-exposure
  class (auth file landing in a backup/paste without its passphrase) and makes the
  auth file safe to back up as-is.

If auth breaks: mkb79's Python `audible-cli` uses a compatible auth file format and can
serve as a fallback; auth files are importable in both directions.

## Setup choices (`audible setup`)

Decisions made during setup, with reasoning — keep these on re-setup:

| Prompt | Choice | Why |
|--------|--------|-----|
| Decrypt backend | **ffmpeg** | aaxclean-cli's Linux builds are glibc-only (.NET NativeAOT, no musl variant) — they don't run on Alpine. ffmpeg from apk is musl-native. |
| Filename mode / template | `custom`, `%publication%/%fulltitle%` | Closest to `<author>/<series>/<title>`: there is **no `%author%` variable** (list fields excluded by design) and no conditional segments — an empty `%publication%` renders as an `unknown/` folder for standalone titles. Not a one-way door: `audible download reorganize --dry-run --filename-template "…"` migrates existing files to a new template later (DB tracks old paths — don't hand-move files on the NAS). |
| Chapter title layout(s) | `tree,flat` | Only controls which named-chapter sidecar JSONs are saved (tiny). `flat` maps 1:1 onto m4b chapters (needed if names are ever baked in); `tree` keeps the hierarchy that can't be losslessly reconstructed later. |
| Max filename length | `230` (default) | Filesystems cap a name at 255 bytes; audible-rs appends fixed suffixes (quality token, `-chapters-*.json`, extension) after the template. `0` = ENAMETOOLONG on the first long subtitle, at 4 a.m., in cron. |
| Change history | `90` days (default) | Audit log only (`library changes`); no role in `--missing`. Lives in the container's disposable DB anyway. |
| Keep source AAX(C) | **No, delete after decryption** | Decryption is a lossless remux (`-c copy`) — the m4b has identical audio and *is* the DRM-free archive. Re-downloading is what this pet automates. |
| Encrypt auth file | **Yes** | See Auth section. |

**Chapter marks:** the decrypted m4b has correct chapter *boundaries* (embedded AAX(C)
markers, copied by ffmpeg's default chapter mapping) but generic *titles* ("Chapter 1").
The properly named chapters land in the sidecar JSON — audible-rs does not merge them
into the m4b (neither via ffmpeg nor aaxclean-cli). If named titles ever matter: remux
the m4b with ffmetadata from the flat JSON, or let Audiobookshelf fetch names itself.

## Scheduled sync

`/usr/local/bin/audible-sync.sh` (check `audible download --help` for exact flags):

```sh
#!/bin/sh
set -eu
audible library sync
audible download --missing --output-dir /data/audiobooks
```

Downloading straight to the NFS mount has a nice side effect: the full library is
visible to the tool, so `--missing` is correct even if it determines missing titles
by looking at files on disk rather than its local database.

Cron (busybox crond, enabled by default on the Proxmox Alpine template):

```sh
echo '0 4 * * * /usr/local/bin/audible-sync.sh >> /var/log/audible-sync.log 2>&1' >> /etc/crontabs/root
rc-service crond restart
```

## Recovery

Everything except the auth file is disposable: recreate the container from this runbook,
re-add the `mp0` bind mount, and redo the login — or restore the encrypted auth file
from backup together with its passphrase from Vaultwarden. Downloaded books live on the
NAS, not in the container.
