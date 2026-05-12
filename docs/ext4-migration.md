# PVE Migration: ZFS → ext4 + SATA SSD

Migrates Proxmox from a single-disk ZFS setup to ext4 on NVMe with a separate SATA SSD for
Home Assistant and other backed-up VMs. Eliminates ZFS ARC memory overhead (~6 GB) and the
swap-on-zvol deadlock risk. See `docs/memory-situation.md` for the background.

## Goals

| Goal | How |
|------|-----|
| Eliminate ZFS ARC | No ZFS anywhere after migration |
| Eliminate swap-on-zvol deadlock | Safe LVM LV swap on NVMe (ext4 install) |
| Isolate Longhorn I/O from backup I/O | Talos VMs on NVMe, HA + backed-up VMs on SATA SSD |
| Preserve all VM data | vzdump to NAS before reinstall, qmrestore after |

## Storage Layout (Target)

```
NVMe 1 TB — PVE install target (ext4)
├── /dev/nvme0n1p1   EFI (512 MB)
└── /dev/nvme0n1p2   LVM PV → VG "pve"  (auto-created by installer)
    ├── pve/root     ext4  ~100 GB   PVE OS
    ├── pve/swap     LV    ~8 GB     Safe swap (raw LV, no deadlock)
    └── pve/data     LVM thin pool   "local-lvm" storage (~890 GB)
                     └── talos-controlplane-1 (virtio0 64 GB, virtio1 8 GB)
                         talos-worker-1       (virtio0 64 GB, virtio1 8 GB, virtio2 264 GB)
                         talos-worker-2       (virtio0 64 GB, virtio1 8 GB, virtio2 264 GB)
                         Total allocated: ~744 GB — fits with ~150 GB headroom

SATA SSD 512 GB — manual setup post-install
└── /dev/sda1        LVM PV → VG "data-sata" → LVM thin pool (~500 GB)
                     "data-sata" storage
                     └── Home Assistant VM
                         other backed-up VMs
```

**Why this layout achieves I/O isolation:** PVE backup jobs read HA VM disks → those reads
now hit SATA SSD. Longhorn rebuilds read/write worker disks → those hit NVMe. The two
workloads that caused the original Sunday crashes are on separate physical disks.

---

## Phase 1 — Pre-Migration Preparation

### 1.1 Update Terraform for new storage pool name

Every `datastore_id` in `terraform/nodes.tf` currently reads `local-zfs`. After migration
the pool is called `local-lvm`. This is a global replace — no exceptions, since all
Terraform-managed VMs (Talos only) land on the NVMe pool.

```diff
-    datastore_id = "local-zfs"
+    datastore_id = "local-lvm"
```

This affects: `efi_disk`, `tpm_state`, `initialization`, `virtio0`, `virtio1`, `virtio2`
on both the `control_plane` and `workers` resources.

Commit before migration day:
```bash
git add terraform/nodes.tf
git commit -m "feat(terraform): migrate storage from local-zfs to local-lvm"
```

### 1.2 Back up PVE configuration

On the Proxmox host:
```bash
mkdir -p /tmp/pve-backup

# VM configs, storage definitions, backup jobs, user/auth
cp -a /etc/pve/qemu-server/   /tmp/pve-backup/
cp    /etc/pve/storage.cfg     /tmp/pve-backup/
cp    /etc/pve/jobs.cfg        /tmp/pve-backup/  2>/dev/null || true
cp    /etc/pve/user.cfg        /tmp/pve-backup/
cp    /etc/pve/priv/shadow.cfg /tmp/pve-backup/  2>/dev/null || true

# Network bridges — critical, must be restored before starting VMs
cp    /etc/network/interfaces  /tmp/pve-backup/

# System tuning
cp -a /etc/sysctl.d/           /tmp/pve-backup/

# Copy to NAS
rsync -av /tmp/pve-backup/ root@192.168.123.5:/path/to/backup/pve-config/
```

### 1.3 Back up VM disks (vzdump to NAS)

**Shut down all VMs cleanly before backing up.** Longhorn and etcd must not be running
mid-write during vzdump.

```bash
# Shut down workers first (drains Longhorn), then control plane, then HA and others
qm shutdown 220 && qm shutdown 221
qm shutdown 200
# Shut down HA VM and any other VMs
qm shutdown <ha-vmid>

# Verify all stopped
qm list

# vzdump all VMs to NAS
vzdump 200       --storage <nas-backup-storage-id> --mode stop --compress zstd
vzdump 220       --storage <nas-backup-storage-id> --mode stop --compress zstd
vzdump 221       --storage <nas-backup-storage-id> --mode stop --compress zstd
vzdump <ha-vmid> --storage <nas-backup-storage-id> --mode stop --compress zstd
```

Replace `<nas-backup-storage-id>` with the Proxmox storage ID for your NAS (Datacenter →
Storage).

> The Talos VMs (200, 220, 221) are not covered by the regular PVE backup schedule — the
> explicit vzdump above is the only copy. Do not skip it.

### 1.4 Verify backups before wiping

```bash
# Confirm all VMs have recent .vma.zst files on NAS
pvesm list <nas-backup-storage-id> --vmid 200
pvesm list <nas-backup-storage-id> --vmid 220
pvesm list <nas-backup-storage-id> --vmid 221
pvesm list <nas-backup-storage-id> --vmid <ha-vmid>
```

**Do not proceed to Phase 2 until all backups are confirmed present on NAS.**

---

## Phase 2 — Hardware Installation

1. Power off the Proxmox host
2. Install the 512 GB SATA SSD
3. Confirm BIOS detects both drives (NVMe + SATA) before booting the installer
4. Prepare a USB stick with the latest Proxmox VE installer ISO

---

## Phase 3 — PVE Reinstall

1. Boot from the Proxmox installer USB
2. When asked for the target disk: **select the NVMe**
3. Under filesystem options: select **ext4** (not ZFS)
   - The installer will auto-create a small LVM swap LV — this is safe (raw LV, no deadlock)
4. Set hostname, IP, and root password as before

> **Do not touch the SATA SSD during installation.** Leave it unpartitioned — it will be
> configured manually after PVE boots.

---

## Phase 4 — Post-Install Host Configuration

### 4.1 Restore network bridges

The PVE installer creates a default `vmbr0`. You need `vmbr0` (management) and `vmbr1`
(workload). Restore the backed-up network config before starting any VMs:

```bash
cp /path/to/pve-backup/interfaces /etc/network/interfaces
systemctl restart networking
```

Verify both bridges are up:
```bash
ip link show vmbr0
ip link show vmbr1
```

### 4.2 Restore system tuning

```bash
cp /path/to/pve-backup/sysctl.d/99-proxmox.conf /etc/sysctl.d/
sysctl --system
```

Confirm:
```bash
sysctl vm.swappiness   # expect 10
```

Note: `/etc/modprobe.d/zfs.conf` (ARC cap) is no longer needed — ZFS is gone.

### 4.3 Add NAS as backup storage

Datacenter → Storage → Add → NFS (or SMB/CIFS) — point to your NAS backup location.
This makes the vzdump files accessible for qmrestore in the next phase.

### 4.4 Set up data-sata LVM thin pool

```bash
# Partition the SATA SSD — single partition, full disk for LVM
parted /dev/sda mklabel gpt
parted /dev/sda mkpart primary 0% 100%

# Create LVM thin pool
pvcreate /dev/sda1
vgcreate data-sata /dev/sda1
lvcreate -l 100%FREE --thinpool data-sata-pool data-sata

# Verify
lvs data-sata
```

Register in Proxmox: **Datacenter → Storage → Add → LVM-Thin**
- ID: `data-sata`
- Volume Group: `data-sata`
- Thin Pool: `data-sata-pool`
- Content: Disk image

### 4.5 Restore vzdump bandwidth limit

Datacenter → Backup → Options → Bandwidth limit: **50 MiB/s**

---

## Phase 5 — VM Restoration

### 5.1 Restore Talos VMs to local-lvm (NVMe)

```bash
qmrestore <path-to-vzdump-200.vma.zst> 200 --storage local-lvm --unique false
qmrestore <path-to-vzdump-220.vma.zst> 220 --storage local-lvm --unique false
qmrestore <path-to-vzdump-221.vma.zst> 221 --storage local-lvm --unique false
```

All disks (including worker virtio2 Longhorn disks) land on `local-lvm` on the NVMe —
no disk move needed.

### 5.2 Restore HA and other VMs to data-sata (SATA SSD)

```bash
qmrestore <path-to-vzdump-<ha-vmid>.vma.zst> <ha-vmid> --storage data-sata --unique false
# Repeat for any other VMs
```

### 5.3 Verify disk placement

```bash
# Talos VMs — all disks should be on local-lvm
qm config 200 | grep -E 'virtio|efidisk|tpmstate'
qm config 220 | grep -E 'virtio|efidisk|tpmstate'
qm config 221 | grep -E 'virtio|efidisk|tpmstate'

# HA VM — should be on data-sata
qm config <ha-vmid> | grep -E 'virtio|scsi|ide'
```

---

## Phase 6 — Kubernetes Recovery

### 6.1 Start VMs in order

```bash
# Control plane first — etcd must be up before workers join
qm start 200

# Wait ~60s for Talos to boot and etcd to become healthy, then start workers
qm start 220
qm start 221
```

### 6.2 Verify cluster

```bash
export KUBECONFIG=/path/to/kubeconfig.yaml

kubectl get nodes          # all three should become Ready
kubectl get pods -A        # watch for crash loops
```

### 6.3 Verify Longhorn

```bash
kubectl -n longhorn-system get volumes.longhorn.io
```

If any volumes show Degraded: expected if a replica was mid-rebuild at backup time.
Longhorn rebuilds automatically. With `concurrentReplicaRebuildPerNodeLimit: 3` rebuilds
complete in the background without saturating I/O.

---

## Phase 7 — Terraform State Reconciliation

The Terraform state is stale after reinstall (references VMs that were destroyed and
recreated). Import the restored VMs back into state.

### 7.1 Import VMs

```bash
cd terraform

terraform import 'proxmox_virtual_environment_vm.control_plane["talos-controlplane-1"]' proxmox/200
terraform import 'proxmox_virtual_environment_vm.workers["talos-worker-1"]' proxmox/220
terraform import 'proxmox_virtual_environment_vm.workers["talos-worker-2"]' proxmox/221
```

### 7.2 Verify plan shows no destructive changes

```bash
terraform plan
```

Expected: minor diffs only (tags, description). There should be **no disk replace
operations**. If `terraform plan` shows a disk being destroyed and recreated, do not apply
— investigate which attribute is causing the diff before proceeding.

### 7.3 Apply

```bash
terraform apply
```

---

## Verification Checklist

- [ ] PVE boots from NVMe, no ZFS in `lsblk` output
- [ ] `swapon --show` shows LV on NVMe (`/dev/pve/swap`), not a zvol
- [ ] `sysctl vm.swappiness` returns 10
- [ ] Proxmox storage shows `local-lvm` and `data-sata` as active pools
- [ ] All Talos VMs running with correct VMIDs (200, 220, 221)
- [ ] All Talos VM disks on `local-lvm` (`qm config 200/220/221`)
- [ ] HA VM and other VMs restored and running on `data-sata`
- [ ] `kubectl get nodes` — all Ready
- [ ] `kubectl get pods -A` — no unexpected CrashLoopBackOff
- [ ] Longhorn volumes all Healthy (may take a few minutes for rebuilds)
- [ ] Traefik serving HTTPS (ACME cert from acme.json survives since PVC data was restored)
- [ ] CrowdSec LAPI pod running
- [ ] `terraform plan` shows no changes (or only trivial diffs)

---

## Rollback

If anything goes wrong before wiping the NVMe: the original ZFS setup is intact — reboot
back into the old PVE installation.

If something goes wrong after wiping:
- All VMs can be restored from NAS vzdump onto any storage pool
- Kubernetes state (etcd) is in the control plane vzdump
- Longhorn data is in the worker vzdump (virtio2 content)
- Git history has all manifests — Flux will reconcile any missing Kubernetes objects
