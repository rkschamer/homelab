# Proxmox VE Configuration

## Overview

The homelab runs on a single Proxmox VE 9.x node (`proxmox`, `192.168.123.8:8006`). All VMs are provisioned and managed by Terraform using the `bpg/proxmox` provider. The node is accessed via Traefik reverse proxy at `https://pve.kschamer.info` for normal use, and directly at `https://192.168.123.8:8006` for emergency access.

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
| TPM           | v2.0 on local-zfs          | Required by Talos for measured boot            |
| QEMU agent    | enabled                    | Needed for graceful shutdown and IP reporting  |
| OS type       | l26 (Linux 2.6–5.x)        | Correct VirtIO driver selection in Proxmox UI  |

### Disk Layout (Workers)

| Interface | Datastore  | Purpose                         |
|-----------|------------|---------------------------------|
| virtio0   | local-zfs  | System disk (64 GB)             |
| virtio1   | local-zfs  | Swap disk (8 GB)                |
| virtio2   | local-zfs  | Longhorn data disk (264 GB)     |

Control plane VMs have no virtio2 — Longhorn is workers-only.

All disks use `discard = on` (TRIM pass-through for ZFS thin provisioning). Longhorn data disks set `backup = false` because Longhorn handles its own replication.

### ISO / CDRom Lifecycle

The Talos ISO is downloaded once via `proxmox_download_file` and attached to all VMs. After initial provisioning the CDRom is no longer needed. The Terraform lifecycle rule `ignore_changes = [cdrom]` prevents Terraform from re-attaching (or re-installing) when the ISO reference changes on a Talos version bump.

> **After first boot:** eject the ISO from each VM in the Proxmox UI before configuring nodes via `talosctl`.

---

## Storage

| Datastore  | Type      | Usage                                      |
|------------|-----------|--------------------------------------------|
| local-zfs  | ZFS pool  | All VM disks (system, swap, EFI, TPM, Longhorn data) |
| local      | Directory | ISO images, snippets                       |
| nas        | NFS/CIFS  | External NAS (backup target)               |

ZFS provides thin provisioning, compression, and snapshots. `discard = on` on all virtio disks ensures freed blocks are returned to the pool.

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
