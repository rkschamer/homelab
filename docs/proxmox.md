# Proxmox VE Configuration

## Overview

The homelab runs on a single Proxmox VE 9.x node (`proxmox`, `192.168.123.8:8006`). All VMs are provisioned and managed by Terraform using the `bpg/proxmox` provider. The node is accessed via Traefik reverse proxy at `https://pve.kschamer.info` for normal use, and directly at `https://192.168.123.8:8006` for emergency access.

Historical note: this host was migrated from ZFS-on-NVMe to ext4/LVM on NVMe in 2026-06 to eliminate the ARC memory overhead and the swap-on-zvol deadlock risk. See [ext4-migration.md](ext4-migration.md) for the migration procedure and [memory-situation.md](memory-situation.md) for the current memory posture.

---

## Network Bridges

Two Linux bridges are configured on the Proxmox host to implement physical network separation:

| Bridge | Network           | Purpose                                   |
|--------|-------------------|-------------------------------------------|
| vmbr0  | 192.168.123.0/24  | Management — control plane and admin access |
| vmbr1  | 10.10.20.0/24     | Workload — all worker nodes               |

The control plane VM has NICs on **both** bridges, making it a bastion/router between management and workload networks. Workers are attached to vmbr1 only. See [network-architecture.md](network-architecture.md) for full routing details.

---

## VM Configuration

All VMs use a consistent hardware profile defined in Terraform:

| Setting       | Value                      | Reason                                         |
|---------------|----------------------------|------------------------------------------------|
| BIOS          | OVMF (UEFI)                | Required for Secure Boot and TPM 2.0           |
| Machine type  | q35                        | Modern PCIe bus; required for OVMF             |
| CPU type      | host                       | Pass-through host CPU flags for best performance |
| Secure Boot   | `pre_enrolled_keys = false` | Lets Talos auto-enroll its own Secure Boot keys |
| TPM           | v2.0 on local-lvm          | Required by Talos for measured boot            |
| QEMU agent    | enabled                    | Needed for graceful shutdown and IP reporting  |
| OS type       | l26 (Linux 2.6–5.x)        | Correct VirtIO driver selection in Proxmox UI  |

### Memory Allocation

| VM | Memory | Notes |
|----|--------|-------|
| talos-controlplane-1 | 6 GB | Bumped from 4 GB after 2026-07-01 apiserver OOM |
| talos-worker-1 | 6 GB | Rolled back from 8 GB to keep the host envelope |
| talos-worker-2 | 6 GB | Same |

Swap is **disabled** on all Talos nodes — no swap disk, no swap partition, no `LimitedSwap` kubelet policy. The Proxmox host itself keeps its installer-created `pve/swap` LV with `vm.swappiness=10` as a safety valve. Full rationale in [memory-situation.md](memory-situation.md).

### Disk Layout

**Control plane:**

| Interface | Datastore  | Size  | Purpose                        |
|-----------|------------|-------|--------------------------------|
| virtio0   | local-lvm  | 64 GB | System disk (Talos)            |

**Workers:**

| Interface | Datastore  | Size   | Purpose                        |
|-----------|------------|--------|--------------------------------|
| virtio0   | local-lvm  | 64 GB  | System disk (Talos)            |
| virtio2   | local-lvm  | 264 GB | Longhorn data disk (LUKS + TPM-encrypted; matched by `disk.size > 100 GiB` in the Talos UserVolumeConfig) |

There is no virtio1 slot — the pre-migration swap disk was removed as part of the ext4 migration.

All disks use `discard = on` (TRIM pass-through so LVM-thin can reclaim freed blocks). Longhorn data disks set `backup = false` because Longhorn handles its own replication.

### ISO / CDRom Lifecycle

The Talos ISO is downloaded once via `proxmox_download_file` and attached to all VMs. After initial provisioning the CDRom is no longer needed. The Terraform lifecycle rule `ignore_changes = [cdrom]` prevents Terraform from re-attaching (or re-installing) when the ISO reference changes on a Talos version bump.

> **After first boot:** eject the ISO from each VM in the Proxmox UI before configuring nodes via `talosctl`.

---

## Storage

| Datastore  | Backend                | Usage                                          |
|------------|------------------------|------------------------------------------------|
| local-lvm  | LVM-thin on NVMe (ext4 root)  | All VM disks (system, EFI, TPM, Longhorn data) |
| local      | Directory              | ISO images, snippets                           |
| data-sata  | LVM-thin on 512 GB SATA SSD | Spare capacity (unused; reserved for future workloads) |
| nas        | NFS                    | Synology `192.168.123.5:/volume1/backups` — vzdump target |

LVM-thin provides thin provisioning and snapshot support. `discard = on` on all virtio disks ensures freed blocks are returned to the pool. `issue_discards = 1` is set in `/etc/lvm/lvm.conf` so LVM itself passes trims down to the SSD.

---

## Users and Authentication

Two Proxmox users exist:

| User        | Realm | TFA      | Purpose                          |
|-------------|-------|----------|----------------------------------|
| root        | pam   | Yes      | Admin — Linux root account       |
| terraform   | pve   | No       | Terraform API automation         |

### TFA for root@pam

`root@pam` has multiple second factors enrolled:

| Type     | Description     |
|----------|-----------------|
| recovery | Backup recovery codes |
| totp     | Google Authenticator (private google) |
| webauthn | YubiKey (rene, steff), notebook-work, Bitwarden passkey |

**Important WebAuthn configuration:** the WebAuthn `rp_id` is `pve.kschamer.info`. The **Origin** (domain lockdown) field in Datacenter → Options → WebAuthn must be set to `https://pve.kschamer.info`.

Without a locked-down origin, Proxmox derives `rp_origin` from the incoming request. When accessing via direct IP (`https://192.168.123.8:8006`), `rp_id` (`pve.kschamer.info`) fails the WebAuthn effective-domain check against the IP origin, crashing the TFA context before any method can be offered — causing a 401 even though the password is correct.

With the origin locked to `https://pve.kschamer.info`, the context always initialises successfully. WebAuthn itself still won't work from the IP (browser-side credential binding), but the TFA dialog is presented and **TOTP can be selected as the fallback**.

### Emergency Access via Direct IP

1. Navigate to `https://192.168.123.8:8006`
2. Username: `root`, Realm: `Linux PAM`
3. Enter password — do **not** rely on browser autofill (credentials are saved per origin and may differ)
4. When the TFA dialog appears, select **TOTP** and enter the Google Authenticator code

### Terraform API Token

The `terraform@pve` user authenticates via an API token (no interactive login needed):

```
Token ID:  terraform@pve!terraform-token
```

The secret is stored in `terraform/terraform.tfvars` (encrypted with git-crypt).

---

## Traefik Ingress

The Proxmox UI is exposed externally via an IngressRoute in [flux/dmz/traefik/routes-bridge.yaml](../flux/dmz/traefik/routes-bridge.yaml):

```
https://pve.kschamer.info  →  ext-pve service  →  192.168.123.8:8006
```

- TLS is terminated by Traefik (Let's Encrypt wildcard cert for `*.kschamer.info`)
- Backend uses `insecureSkipVerify: true` because Proxmox presents a self-signed cert on port 8006
- The CrowdSec bouncer middleware is applied on this route

When Traefik or the cluster is unavailable, use the direct IP path described above.
