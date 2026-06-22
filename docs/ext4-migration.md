# PVE Migration: ZFS → ext4

Migrates Proxmox from a single-disk ZFS setup to ext4 on NVMe. Eliminates ZFS ARC memory
overhead (~6 GB freed even after the current cap) and removes the swap-on-zvol deadlock risk
permanently in firmware (not just at runtime). See `docs/memory-situation.md` for the background.

> **Note:** Disabling swap already stabilized the cluster. This migration is still worth doing
> to recover the 6 GB ARC headroom and make the no-swap / no-ZFS posture durable across
> reinstalls.

The SATA SSD is installed alongside NVMe during Phase 1 and set up as a second pool (`data-sata`)
post-install. It is not used for any current VM — all disks stay on NVMe — but it is ready as
spare capacity for future backed-up VMs or Longhorn offload.

## Goals

| Goal | How |
|------|-----|
| Eliminate ZFS ARC (~6 GB) | No ZFS anywhere after migration |
| Make no-swap posture permanent | `swap.yaml` manifests and virtio1 disks removed before migration; ext4 install has no zvol |
| Preserve all VM data | vzdump to NAS before reinstall, qmrestore after |

## Storage Layout (Target)

```
NVMe 1 TB — PVE install target (ext4)
├── /dev/nvme0n1p1   EFI (512 MB)
└── /dev/nvme0n1p2   LVM PV → VG "pve"  (auto-created by installer)
    ├── pve/root     ext4  ~100 GB   PVE OS
    ├── pve/swap     LV    ~8 GB     NOTE: disable post-install (see 3.3)
    └── pve/data     LVM thin pool   "local-lvm" storage (~890 GB)
                     └── talos-controlplane-1 (virtio0 64 GB)
                         talos-worker-1       (virtio0 64 GB, virtio2 264 GB)
                         talos-worker-2       (virtio0 64 GB, virtio2 264 GB)
                         efi_disk + tpm_state per node (~0.5 GB each)
                         Total allocated: ~723 GB — fits with ~167 GB headroom

SATA SSD 512 GB — set up post-install, currently unused
└── /dev/sda1        LVM PV → VG "data-sata" → LVM thin pool (~500 GB)
                     "data-sata" storage  (spare capacity for future use)
```

> **virtio1 (swap) disks are removed before migration.** With both `swap.yaml` manifests and
> the Terraform virtio1 disk definitions deleted, the VMs will have no swap device — matching
> the current stable state.

---

## Phase 0 — Prerequisites (do this before migration day)

### 0.1 Export Vaultwarden vault offline

Vaultwarden holds the git-crypt key and the sealed-secrets master key. The rebuilt cluster
cannot run Vaultwarden until the cluster is healthy; the cluster cannot be managed without
those keys. Break the circular dependency before wiping anything.

1. In the Vaultwarden web UI: **Tools → Export vault** → save the JSON file to your
   operator workstation (not the NAS — you need it before the NAS backup storage is
   re-added to PVE).
2. Confirm the git-crypt key file is on your operator workstation, not only on the PVE host.
3. Export the in-cluster sealed-secrets master key to the NAS:
   ```bash
   kubectl -n kube-system get secret sealed-secrets-key \
     -o jsonpath='{.data}' | base64 -d > /tmp/sealed-secrets-key.json
   # Or use the kubeseal --fetch-cert approach for the public cert
   kubectl -n kube-system get secret \
     -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
     -o yaml > /tmp/sealed-secrets-master-key.yaml
   rsync /tmp/sealed-secrets-master-key.yaml root@192.168.123.5:/volume1/backup/pve-config/
   ```

### 0.2 Remove swap manifests and virtio1 disks

This makes the no-swap posture permanent and removes the virtio1 VM disk before migration.
The swap.yaml manifests select any non-system virtio disk — removing them and the underlying
disk prevents Talos from creating swap on whatever disk ends up at that slot after migration.

```bash
rm talos/manifests/talos-controlplane-1/swap.yaml
rm talos/manifests/talos-worker-1/swap.yaml
rm talos/manifests/talos-worker-2/swap.yaml
```

In `terraform/nodes.tf`, delete the `# Swap disk` block from both `control_plane` and
`workers` resources (the `disk { interface = "virtio1" ... }` block in each):

```diff
-  # Swap disk
-  disk {
-    datastore_id = "local-zfs"
-    interface    = "virtio1"
-    size         = each.value.disks.swap_size_in_gb
-    discard      = "on"
-    backup       = false
-  }
-
```

Remove `swap_size_in_gb` from `terraform/terraform.tfvars` (under both `control_plane` and
`worker_nodes` disk sections).

Apply and talosctl apply-config to each node so Talos drops the swap configuration:
```bash
cd terraform && terraform apply   # removes virtio1 from PVE VMs
talosctl apply-config --nodes 192.168.123.20 --file talos/gen/controlplane.yaml
talosctl apply-config --nodes 10.10.20.21    --file talos/gen/worker-talos-worker-1.yaml
talosctl apply-config --nodes 10.10.20.22    --file talos/gen/worker-talos-worker-2.yaml
```

Verify swap is gone on all nodes:
```bash
talosctl -n 192.168.123.20,10.10.20.21,10.10.20.22 read /proc/swaps
# Expected: Filename/Type/Size header only — no entries
```

### 0.3 Update Terraform for new storage pool name

Every `datastore_id` in `terraform/nodes.tf` currently reads `local-zfs`. After migration
all disks land on the NVMe pool `local-lvm`. This is a global replace — no exceptions.

```diff
-    datastore_id = "local-zfs"
+    datastore_id = "local-lvm"
```

This affects: `efi_disk`, `tpm_state`, `initialization`, `virtio0`, and `virtio2` on both
the `control_plane` and `workers` resources.

Also confirm `terraform/image.tf` — the ISO download already targets `"local"`, not
`"local-zfs"`, so no change needed there.

Commit (but do not apply — Terraform apply happens in Phase 7 after import):
```bash
git add terraform/nodes.tf terraform/terraform.tfvars talos/manifests/
git commit -m "feat(terraform): migrate storage from local-zfs to local-lvm, remove swap disks"
```

### 0.4 Back up PVE configuration

On the Proxmox host:
```bash
mkdir -p /tmp/pve-backup

# VM configs, storage definitions, backup jobs, user/auth
cp -a /etc/pve/qemu-server/      /tmp/pve-backup/
cp    /etc/pve/storage.cfg        /tmp/pve-backup/
cp    /etc/pve/datacenter.cfg     /tmp/pve-backup/  2>/dev/null || true
cp    /etc/pve/jobs.cfg           /tmp/pve-backup/  2>/dev/null || true
cp    /etc/pve/user.cfg           /tmp/pve-backup/
cp -a /etc/pve/priv/             /tmp/pve-backup/pve-priv/  2>/dev/null || true

# Network bridges — critical, must be restored before starting VMs
cp    /etc/network/interfaces     /tmp/pve-backup/

# SSH and host identity
cp -a /root/.ssh/                 /tmp/pve-backup/root-ssh/
cp    /etc/ssh/ssh_host_*         /tmp/pve-backup/  2>/dev/null || true
cp    /etc/hosts                  /tmp/pve-backup/

# System tuning
cp -a /etc/sysctl.d/              /tmp/pve-backup/

# Copy to NAS (see Appendix for Synology SSH setup)
rsync -av /tmp/pve-backup/ root@192.168.123.5:/volume1/backup/pve-config/
```

> `storage.cfg` is backed up for reference only — do **not** restore it verbatim after
> reinstall; it still references `local-zfs`. Re-create storage entries manually (§3.7/3.8).

### 0.5 Check Longhorn volume health

All volumes must be healthy before backup. If any volume is rebuilding, wait.

```bash
kubectl -n longhorn-system get volumes.longhorn.io \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.robustness}{"\n"}{end}'
# All lines must show "healthy" — do not proceed until they do
```

### 0.6 Back up VM disks (vzdump to NAS)

**Properly quiesce Longhorn before shutting down.** Do not simply `qm shutdown` workers.

```bash
# 1. Scale down all Longhorn-PVC-using workloads to detach volumes
#    (repeat for every namespace that has PVCs backed by Longhorn)
kubectl -n trusted scale deploy --all --replicas=0
kubectl -n dmz scale deploy --all --replicas=0
kubectl -n untrusted scale deploy --all --replicas=0
kubectl -n monitoring scale deploy --all --replicas=0

# 2. Wait for volumes to detach
kubectl -n longhorn-system get volumes.longhorn.io
# Wait until all show state: "detached"

# 3. Cordon and drain workers
kubectl drain talos-worker-1 --ignore-daemonsets --delete-emptydir-data
kubectl drain talos-worker-2 --ignore-daemonsets --delete-emptydir-data

# 4. Shut down workers, then control plane
qm shutdown 220
qm shutdown 221
qm shutdown 200

# 5. Verify all stopped
qm list

# 6. vzdump all VMs to NAS
vzdump 200 --storage <nas-backup-storage-id> --mode stop --compress zstd
vzdump 220 --storage <nas-backup-storage-id> --mode stop --compress zstd
vzdump 221 --storage <nas-backup-storage-id> --mode stop --compress zstd
```

Replace `<nas-backup-storage-id>` with the Proxmox storage ID for your NAS (Datacenter →
Storage).

> The Talos VMs (200, 220, 221) are not covered by the regular PVE backup schedule — the
> explicit vzdump above is the only copy. Do not skip it.

### 0.7 Verify backups before wiping

```bash
# Confirm all VMs have recent .vma.zst files on NAS
pvesm list <nas-backup-storage-id> --vmid 200
pvesm list <nas-backup-storage-id> --vmid 220
pvesm list <nas-backup-storage-id> --vmid 221

# Verify integrity — do this before touching hardware
vma verify $(pvesm path <nas-backup-storage-id>:backup/vzdump-qemu-200*.vma.zst)
vma verify $(pvesm path <nas-backup-storage-id>:backup/vzdump-qemu-220*.vma.zst)
vma verify $(pvesm path <nas-backup-storage-id>:backup/vzdump-qemu-221*.vma.zst)
```

**Do not proceed to Phase 1 until all backups are verified present and intact on NAS.**

---

## Phase 1 — Hardware Installation

1. Power off the Proxmox host
2. Install the 512 GB SATA SSD
3. Confirm BIOS detects both drives (NVMe + SATA) before booting the installer
4. Prepare a USB stick with the latest Proxmox VE installer ISO

---

## Phase 2 — PVE Reinstall

1. Boot from the Proxmox installer USB
2. When asked for the target disk: **select the NVMe**
3. Under filesystem options: select **ext4** (not ZFS)
   - The installer creates an LVM `pve/swap` LV automatically — this will be disabled in
     Phase 3 (it's a raw LV, not a zvol, so no deadlock, but swap is not needed)
4. Set hostname, IP, and root password as before

> **Do not touch the SATA SSD during installation.** Leave it unpartitioned — it will be
> configured manually after PVE boots.

---

## Phase 3 — Post-Install Host Configuration

### 3.1 Restore network bridges

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

### 3.2 Restore system tuning

```bash
cp /path/to/pve-backup/sysctl.d/99-proxmox.conf /etc/sysctl.d/
sysctl --system
```

Confirm:
```bash
sysctl vm.swappiness   # expect 10
```

Note: `/etc/modprobe.d/zfs.conf` (ARC cap) is no longer needed — ZFS is gone.

### 3.3 Disable the installer-created swap LV

The installer creates a `pve/swap` LV. Disable it to match the stable no-swap posture:

```bash
swapoff -a
# Comment out or remove the swap entry in /etc/fstab
sed -i '/swap/s/^/#/' /etc/fstab

# Optionally reclaim the space
lvremove /dev/pve/swap
# Accept "Do you really want to remove..."
```

Confirm no swap:
```bash
swapon --show   # expect empty
free -h          # swap line should show 0
```

### 3.4 Enable LVM thin discard

Required so thin pools reclaim freed blocks from VMs; without this the pool fills up
even when VMs delete data.

```bash
# Verify current setting
grep issue_discards /etc/lvm/lvm.conf

# Set it if not already 1
sed -i 's/issue_discards = 0/issue_discards = 1/' /etc/lvm/lvm.conf
# Or add it under the devices{} section if missing:
# echo '    issue_discards = 1' >> /etc/lvm/lvm.conf

lvchange --discard passdown pve/data
```

### 3.5 Restore SSH and host identity (optional but recommended)

Restoring the original SSH host keys prevents "host key changed" warnings from your
operator workstation:

```bash
cp /path/to/pve-backup/ssh_host_* /etc/ssh/
systemctl restart ssh
```

Restore authorized keys:
```bash
cp -a /path/to/pve-backup/root-ssh/ /root/.ssh/
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
```

### 3.6 Sync clock before booting VMs

A fresh PVE install may have unsynced time. etcd requires tight clock agreement.

```bash
chronyc tracking          # verify sync
timedatectl status        # verify NTP active
# If not synced: chronyc makestep
```

### 3.7 Add NAS as backup storage

Datacenter → Storage → Add → NFS (or SMB/CIFS) — point to your NAS backup location.
This makes the vzdump files accessible for qmrestore in Phase 5.

### 3.8 Set up data-sata LVM thin pool

```bash
# Partition the SATA SSD — single partition, full disk for LVM
parted --script /dev/sda mklabel gpt
parted --script /dev/sda mkpart primary 0% 100%

# Create LVM thin pool
pvcreate /dev/sda1
vgcreate data-sata /dev/sda1
lvcreate -l 100%FREE --thinpool data-sata-pool data-sata

# Enable discard
lvchange --discard passdown data-sata/data-sata-pool

# Verify
lvs data-sata
```

Register in Proxmox: **Datacenter → Storage → Add → LVM-Thin**
- ID: `data-sata`
- Volume Group: `data-sata`
- Thin Pool: `data-sata-pool`
- Content: Disk image

### 3.9 Restore vzdump bandwidth limit

Datacenter → Backup → Options → Bandwidth limit: **50 MiB/s**

(This is a Datacenter-level setting stored in `datacenter.cfg`, which was wiped with
reinstall. Set it manually here — the backed-up `datacenter.cfg` is for reference only.)

---

## Phase 4 — Clean Up Terraform State

The old Terraform state references VMs and resources on `local-zfs` which no longer exist.
Do not run `terraform import` until the stale state is removed.

```bash
cd terraform

# List all managed resources
terraform state list

# Remove the ISO download resource (the file is gone from PVE after reinstall)
terraform state rm proxmox_download_file.talos_iso

# Remove the VMs (will be re-imported in Phase 6)
terraform state rm 'proxmox_virtual_environment_vm.control_plane["talos-controlplane-1"]'
terraform state rm 'proxmox_virtual_environment_vm.workers["talos-worker-1"]'
terraform state rm 'proxmox_virtual_environment_vm.workers["talos-worker-2"]'
```

---

## Phase 5 — VM Restoration

### 5.1 Restore Talos VMs to local-lvm (NVMe)

`--unique false` preserves the original MAC addresses, which is required for Talos LinkConfig
static IP assignments and DHCP leases to remain valid after restore.

```bash
qmrestore <path-to-vzdump-200.vma.zst> 200 --storage local-lvm --unique false
qmrestore <path-to-vzdump-220.vma.zst> 220 --storage local-lvm --unique false
qmrestore <path-to-vzdump-221.vma.zst> 221 --storage local-lvm --unique false
```

All disks (including worker virtio2 Longhorn disks) land on `local-lvm` on the NVMe — no
disk move needed.

### 5.2 Verify disk placement and MAC addresses

```bash
# All disks should currently be on local-lvm
qm config 200 | grep -E 'virtio|efidisk|tpmstate|net'
qm config 220 | grep -E 'virtio|efidisk|tpmstate|net'
qm config 221 | grep -E 'virtio|efidisk|tpmstate|net'
```

Cross-check the `net` lines against the MAC addresses in `terraform/terraform.tfvars` (under
each node's `network_devices`) — they must match for static IP assignments to survive.

---

## Phase 6 — Kubernetes Recovery

### 6.1 Start VMs in order

```bash
# Control plane first — etcd must be up before workers join
qm start 200

# Wait ~60s for Talos to boot and etcd to become healthy
sleep 60
talosctl -n 192.168.123.20 health --control-plane-nodes 192.168.123.20

# Then start workers
qm start 220
qm start 221
```

### 6.2 Verify cluster

```bash
export TALOSCONFIG="$(pwd)/talos/gen/talosconfig"
export KUBECONFIG="$(pwd)/talos/gen/kubeconfig"

kubectl get nodes          # all three should become Ready
kubectl get pods -A        # watch for crash loops
```

### 6.3 Verify Longhorn

```bash
kubectl -n longhorn-system get volumes.longhorn.io
```

With `concurrentReplicaRebuildPerNodeLimit: 3` (longhorn-release.yaml:84), rebuilds run in
the background. Both replicas are on TPM-encrypted disks. If any volumes show Degraded:
confirm TPM unlock succeeded by checking Talos logs:

```bash
talosctl -n 10.10.20.21 dmesg | grep -i "luks\|tpm\|unlock"
talosctl -n 10.10.20.22 dmesg | grep -i "luks\|tpm\|unlock"
```

If TPM unlock fails on a worker (only one slot, no recovery passphrase), the Longhorn
replica on that worker will be inaccessible. With replicaCount=2, this is a single point of
failure. If this happens:
1. Do not force-delete the volume yet
2. Check whether the other worker's replica is healthy — if yes, data is safe
3. Fix the TPM issue (re-enroll keys via Talos `talosctl reset --graceful` on that node and
   re-join) before Longhorn marks the lost replica as faulted and waits for a third node

### 6.4 Re-scale workloads

```bash
# Restore workload deployments that were scaled to 0 in Phase 0.6
kubectl -n trusted scale deploy --all --replicas=1
kubectl -n dmz scale deploy --all --replicas=1
kubectl -n untrusted scale deploy --all --replicas=1
kubectl -n monitoring scale deploy --all --replicas=1
# Adjust replica counts above to match your actual desired replicas
```

---

## Phase 7 — Terraform State Reconciliation

### 7.1 Import restored VMs

The VMs were recreated by qmrestore. Import them back into the state that was cleaned in
Phase 4.

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

Expected: minor diffs only (tags, description, potentially cdrom). There should be **no disk
replace operations**. If `terraform plan` shows a disk being destroyed and recreated, do not
apply — investigate the diff attribute before proceeding.

### 7.3 Apply

```bash
terraform apply
```

---

## Verification Checklist

- [ ] PVE boots from NVMe, no ZFS in `lsblk` output
- [ ] `swapon --show` is empty (no swap at all)
- [ ] `sysctl vm.swappiness` returns 10
- [ ] Proxmox storage shows `local-lvm` and `data-sata` as active pools
- [ ] LVM discard enabled: `grep issue_discards /etc/lvm/lvm.conf` returns 1
- [ ] All Talos VMs running with correct VMIDs (200, 220, 221)
- [ ] All Talos VM disks on `local-lvm` (`qm config 200/220/221`)
- [ ] MAC addresses on all VMs match `terraform.tfvars` network_devices entries
- [ ] `kubectl get nodes` — all Ready
- [ ] `kubectl get pods -A` — no unexpected CrashLoopBackOff
- [ ] Longhorn volumes all Healthy
- [ ] Longhorn virtio2 LUKS unlock confirmed in worker dmesg
- [ ] Traefik serving HTTPS (ACME cert from acme.json survives since PVC data was restored)
- [ ] CrowdSec LAPI pod running
- [ ] Vaultwarden accessible, vault export matches in-app data
- [ ] `terraform plan` shows no changes (or only trivial cdrom diff)
- [ ] NTP synced: `chronyc tracking`

---

## Rollback

**Before Phase 2 (NVMe wipe):** the original ZFS setup is intact — reboot back into the old
PVE installation at any time.

**The point of no return is the moment the Proxmox installer begins partitioning the NVMe.**
After that, ZFS is gone.

If something goes wrong after wiping:
- All VMs can be restored from NAS vzdump onto any storage pool — run qmrestore and specify
  `--storage local-lvm` or any available pool
- Kubernetes state (etcd) is in the control plane vzdump
- Longhorn data is in the worker vzdump (virtio2 content) — encrypted, but decryptable once
  Talos unlocks the LUKS volume via TPM
- Git history has all manifests — Flux will reconcile any missing Kubernetes objects
  (it does not need re-bootstrapping; it picks up from the restored etcd state)
- Sealed-secrets: if the master key was exported in Phase 0.1, re-import it after cluster
  recovery: `kubectl apply -f /path/to/sealed-secrets-master-key.yaml`

---

## Appendix: Enable SSH on Synology NAS for rsync

The `rsync` commands in this document push backups to `root@192.168.123.5`. Synology DSM
disables SSH by default and restricts root login.

### Enable SSH

1. DSM → **Control Panel** → **Terminal & SNMP** → **Terminal** tab
2. Check **Enable SSH service**; set port (default 22 is fine for LAN-only)
3. Click **Apply**

### Allow root login (required for rsync as root)

By default, DSM blocks root SSH login. Two options:

**Option A — use your admin user instead of root (preferred):**
```bash
# On PVE host, use your DSM admin username
rsync -av /tmp/pve-backup/ admin@192.168.123.5:/volume1/backup/pve-config/
# The path /volume1/backup/ maps to the "backup" shared folder in DSM
```

**Option B — enable root SSH login:**
1. DSM → **Control Panel** → **Terminal & SNMP** → enable SSH (as above)
2. SSH into the NAS as your admin user, then:
   ```bash
   sudo sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
   sudo synoservicectl --restart sshd
   ```
3. Set root password if not set: `sudo passwd root`

> DSM updates may revert sshd_config changes. Re-apply after DSM upgrades if root SSH stops
> working.

### Copy SSH key for passwordless auth

On the PVE host:
```bash
ssh-copy-id admin@192.168.123.5   # or root@... if using Option B
# Test:
ssh admin@192.168.123.5 ls /volume1/backup/
```

### Shared folder path mapping

| DSM Shared Folder | SSH path |
|---|---|
| `backup` | `/volume1/backup/` |
| `homes/admin` | `/var/services/homes/admin/` |

Create the destination folder before running rsync:
```bash
ssh admin@192.168.123.5 mkdir -p /volume1/backup/pve-config/
```
