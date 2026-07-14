# Audible Sync LXC

Downloads purchased Audible titles with [audible-rs](https://github.com/mkb79/audible-rs)
and syncs them to the NAS. Runs as a plain Alpine LXC **pet** on Proxmox — deliberately
not managed by Terraform/Flux. This document is the runbook to rebuild it from scratch.

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

pct create 200 local:vztmpl/<alpine-template>.tar.xz \
  --hostname audible \
  --unprivileged 1 \
  --cores 1 --memory 512 --swap 0 \
  --rootfs <storage>:16 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --onboot 1 --ostype alpine
pct start 200
pct exec 200 -- passwd
```

- **Bridge:** `vmbr0` (management/home LAN) — needs internet and NAS access.
- **Disk:** 16 GB is staging space only; files are rsynced to the NAS after download.

## Install (inside the container)

```sh
apk add ffmpeg rsync curl openssh    # ffmpeg >= 4.4 decrypts .aaxc -> .m4b
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
subcommand. The auth file is encrypted at rest and is rewritten on token refresh —
it is mutable state, so after a container rebuild the login must be redone (or the auth
file restored from a backup).

If auth breaks: mkb79's Python `audible-cli` uses a compatible auth file format and can
serve as a fallback; auth files are importable in both directions.

## Scheduled sync

`/usr/local/bin/audible-sync.sh` (check `audible download --help` for exact flags):

```sh
#!/bin/sh
set -eu
audible library sync
audible download --missing --output-dir /srv/staging
rsync -av /srv/staging/ <nas>:/<audiobooks-path>/
```

Cron (busybox crond, enabled by default on the Proxmox Alpine template):

```sh
echo '0 4 * * * /usr/local/bin/audible-sync.sh >> /var/log/audible-sync.log 2>&1' >> /etc/crontabs/root
rc-service crond restart
```

## Recovery

Everything except the auth file is disposable: recreate the container from this runbook
and redo the login. Downloaded books live on the NAS, not in the container.
