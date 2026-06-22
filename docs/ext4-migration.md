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
| Eliminate swap-on-zvol deadlock | Swap LV on ext4/LVM has no deadlock risk |
| Preserve all VM data | vzdump to NAS before reinstall, qmrestore after |

## Storage Layout (Target)

```
NVMe 1 TB — PVE install target (ext4)
├── /dev/nvme0n1p1   EFI (512 MB)
└── /dev/nvme0n1p2   LVM PV → VG "pve"  (auto-created by installer)
    ├── pve/root     ext4  ~100 GB   PVE OS
    ├── pve/swap     LV    ~8 GB     safe on ext4/LVM (no zvol deadlock risk)
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
   mount -t nfs 192.168.123.5:/volume1/backups /mnt/nas-backup
   cp /tmp/sealed-secrets-master-key.yaml /mnt/nas-backup/pve-config/
   umount /mnt/nas-backup
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

# Copy to NAS
mkdir -p /mnt/nas-backup
mount -t nfs 192.168.123.5:/volume1/backups /mnt/nas-backup
cp -a /tmp/pve-backup/ /mnt/nas-backup/pve-config/
umount /mnt/nas-backup
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

Shut down all VMs cleanly — Talos stops kubelet and syncs filesystems on shutdown, so the
disk images will be consistent for vzdump. Workers first so Longhorn has a chance to flush,
then control plane.

```bash
# Shut down workers first, then control plane
talosctl shutdown --nodes 10.10.20.21,10.10.20.22
# Wait for both to power off, then:
talosctl shutdown --nodes 192.168.123.20

# Verify all stopped
qm list

# vzdump all VMs to NAS
vzdump 200 --storage nas --mode stop --compress zstd
vzdump 220 --storage nas --mode stop --compress zstd
vzdump 221 --storage nas --mode stop --compress zstd

vzdump 111 --storage nas --mode stop --compress zstd
vzdump 151 --storage nas --mode stop --compress zstd
vzdump 110 --storage nas --mode stop --compress zstd
```


> The Talos VMs (200, 220, 221) are not covered by the regular PVE backup schedule — the
> explicit vzdump above is the only copy. Do not skip it.

### 0.7 Verify backups before wiping

```bash
# Confirm all VMs have recent .vma.zst files on NAS
pvesm list nas --vmid 200
pvesm list nas --vmid 220
pvesm list nas --vmid 221

# Verify integrity — vma verify doesn't handle .zst compression; use zstd --test
for vmid in 200 220 221; do
  zstd --test $(pvesm path nas:backup/vzdump-qemu-${vmid}*.vma.zst) && echo "VMID $vmid OK"
done
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
cp /mnt/nas-backup/sysctl.d/99-swap.conf /etc/sysctl.d/
sysctl --system
```

Confirm:
```bash
sysctl vm.swappiness   # expect 10
```

Note: `/etc/modprobe.d/zfs.conf` (ARC cap) is no longer needed — ZFS is gone.

The installer-created `pve/swap` LV is safe to keep. Unlike the old ZFS zvol, an LVM swap LV
is a plain block device with no deadlock risk. With `vm.swappiness=10` it only activates under
genuine memory pressure. Leave it as-is.

### 3.3 Configure APT repositories

The fresh install points at the enterprise repo (requires a subscription) and will nag on
every login. Switch to the no-subscription repo:

```bash
# Disable enterprise repo
echo "# disabled" > /etc/apt/sources.list.d/pve-enterprise.list

# Disable Ceph enterprise repo (also added by installer)
echo "# disabled" > /etc/apt/sources.list.d/ceph.list  2>/dev/null || true

# Add no-subscription repo
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list

apt-get update
```

### 3.4 Restore PVE configuration

Restores users, 2FA, backup job schedules, and host identity. Do this before logging into
the web UI.

```bash
# Wait for pve-cluster to be fully up
systemctl is-active pve-cluster

# Users, API tokens, TOTP/2FA
cp /mnt/nas-backup/pve-config/user.cfg                /etc/pve/
cp /mnt/nas-backup/pve-config/pve-priv/shadow.cfg     /etc/pve/priv/  2>/dev/null || true
cp /mnt/nas-backup/pve-config/pve-priv/tfa.cfg        /etc/pve/priv/  2>/dev/null || true

# Backup job schedules
cp /mnt/nas-backup/pve-config/jobs.cfg           /etc/pve/  2>/dev/null || true

# Hostname entries
cp /mnt/nas-backup/pve-config/hosts              /etc/hosts
```

The web UI will reflect the restored users immediately — no restart needed.

### 3.5 Enable LVM thin discard

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

### 3.6 Restore SSH and host identity (optional but recommended)

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

### 3.7 Sync clock before booting VMs

A fresh PVE install may have unsynced time. etcd requires tight clock agreement.

```bash
chronyc tracking          # verify sync
timedatectl status        # verify NTP active
# If not synced: chronyc makestep
```

### 3.8 Add NAS as backup storage

Datacenter → Storage → Add → NFS:
- Server: `192.168.123.5`
- Export: `/volume1/backups`
- Subdirectory: `/proxmox`
- ID: `nas` (match whatever storage ID you used for vzdump in Phase 0.6)
- Content: VZDump backup file

This makes the vzdump files from Phase 0.6 accessible for qmrestore in Phase 5.

### 3.9 Set up data-sata LVM thin pool

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

### 3.10 Restore datacenter config

Restores the bandwidth limit and other datacenter-wide settings:

```bash
cp /mnt/nas-backup/pve-config/datacenter.cfg /etc/pve/  2>/dev/null || true
```

If the file wasn't backed up, set the bandwidth limit manually:
Datacenter → Backup → Options → Bandwidth limit: **50 MiB/s**

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

## Appendix: Synology NFS Setup

The NFS mount used throughout this document is `192.168.123.5:/volume1/backups`.

### Enable NFS on the Synology

DSM → **Control Panel** → **File Services** → **NFS** tab → check **Enable NFS service** → Apply.

### Grant PVE host access to the shared folder

DSM → **Control Panel** → **Shared Folder** → select `backups` → **Edit** → **NFS Permissions** tab → **Create**:

| Field | Value |
|---|---|
| Hostname or IP | `192.168.123.8` |
| Privilege | Read/Write |
| Squash | **No mapping** |
| Security | sys |
| Enable asynchronous | checked |

**Squash must be "No mapping"** — otherwise root on PVE is remapped to `nobody` and file copies fail with permission errors.

### Mount and use from PVE

```bash
mkdir -p /mnt/nas-backup
mount -t nfs 192.168.123.5:/volume1/backups /mnt/nas-backup

# verify
ls /mnt/nas-backup

umount /mnt/nas-backup
```

The mount is temporary (not in `/etc/fstab`) — mount when needed, unmount when done.
