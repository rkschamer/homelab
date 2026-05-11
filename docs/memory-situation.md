# Proxmox Host Memory Situation

## Hardware

- CPU: AMD Ryzen 5 5600G (6 cores / 12 threads), max supported RAM: 64 GB DDR4
- RAM installed: 32 GB (27 GB visible to OS — remainder reserved by BIOS/iGPU)
- Storage: single NVMe (ZFS pool `rpool`), 512 GB SATA SSD (to be added)

## Root Cause: Chronic Memory Overcommit

The Proxmox host is overcommitted. With all VMs running, RAM demand exceeds physical supply:

| Consumer | RAM |
|---|---|
| talos-worker-1 | 8 GB (→ 6 GB after pending Terraform apply) |
| talos-worker-2 | 8 GB (→ 6 GB after pending Terraform apply) |
| talos-controlplane-1 | 4 GB |
| Home Assistant + other VMs | ~2–4 GB |
| ZFS ARC (uncapped) | up to 26.3 GB |
| PVE overhead | ~1–2 GB |
| **Total demand** | **~27–30 GB on a 27 GB host** |

Any additional load (backup job, OS upgrade, Longhorn rebuild) pushes the host over the edge.

## ZFS ARC Problem

By default, OpenZFS sets `c_max` (maximum ARC size) to roughly 75–80% of physical RAM. On this host that was **26.3 GB** — nearly the entire available memory. Under load, ZFS could expand its cache to the point of starving running VMs and PVE services.

**Fix applied:** ARC capped at 6 GB permanently.

```
# /etc/modprobe.d/zfs.conf
options zfs zfs_arc_max=6442450944
```

This was also applied live without reboot:
```bash
echo 6442450944 > /sys/module/zfs/parameters/zfs_arc_max
```

## Swap on ZFS Zvol — Deadlock

The Proxmox default installation places swap on a ZFS zvol (`rpool/swap`, exposed as `/dev/zd352`). This creates a well-known deadlock under memory pressure:

1. Host runs low on memory
2. Kernel tries to swap in pages from the zvol
3. ZFS needs memory to service the I/O request
4. Neither can proceed — both are waiting on the other

### Observed Symptoms (2026-05-11)

The deadlock manifested during a PVE OS upgrade while Longhorn rebuilds were in progress:

- `pvestatd` blocked in uninterruptible sleep (state D) for 122+ seconds
- `systemd-journald` hit its watchdog timeout (3 min) and was SIGKILL'd — journal corrupted
- `pve-firewall` froze for 357 seconds — VMs lost network connectivity
- `pmxcfs` file locks timed out — scheduler could not read job config
- VMs lost connectivity → Longhorn kubelet heartbeats missed → replica faults on all workers

The same mechanism likely caused prior Sunday night crashes triggered by backup I/O pressure.

**Fix applied:** `vm.swappiness=10` to minimize swap usage under normal conditions.

```
# /etc/sysctl.d/99-proxmox.conf
vm.swappiness=10
```

## Why ZFS Was a Poor Fit Here

ZFS's main benefits (RAID-Z redundancy, large ARC performance) require multiple disks and ample RAM respectively. This host has neither:

- Single NVMe — no redundancy benefit from ZFS
- Constrained RAM — ARC competes directly with VM memory
- Swap-on-zvol — inherited deadlock from default Proxmox install

An ext4/LVM setup would have been more appropriate, but in-place migration is not feasible without a full reinstall and restore. The mitigations below address the symptoms without requiring that.

## Mitigations Applied

| Fix | Status |
|---|---|
| ZFS ARC capped at 6 GB (`/etc/modprobe.d/zfs.conf`) | Done |
| `vm.swappiness=10` (`/etc/sysctl.d/99-proxmox.conf`) | Done |
| Longhorn `concurrentReplicaRebuildPerNodeLimit` raised to 5 | Done (in HelmRelease) |
| PVE backup bandwidth limit set to 50 MiB/s | Done |
| PVE backup fleecing enabled on `local-zfs` | Done |
| Worker RAM reduced from 8 GB to 6 GB | Terraform applied, VMs need restart |

## Open TODOs

### 1. Disable ZFS swap and reclaim the zvol

```bash
swapoff /dev/zd352
# Remove or comment out the swap entry in /etc/fstab
zfs destroy rpool/swap   # verify name first: zfs list -t volume | grep swap
```

This eliminates the deadlock mechanism entirely. Safe to do now — memory headroom improved after worker RAM reduction and ARC cap.

### 2. Install 512 GB SATA SSD

Partition layout:
- 32 GB → raw Linux swap (outside ZFS, no deadlock risk)
- ~480 GB → LVM thin pool for Proxmox storage (`data-sata`)

```bash
parted /dev/sda mklabel gpt
parted /dev/sda mkpart primary linux-swap 0% 7%
parted /dev/sda mkpart primary 7% 100%

mkswap /dev/sda1
# Add to /etc/fstab by UUID

pvcreate /dev/sda2
vgcreate data-sata /dev/sda2
lvcreate -l 100%FREE --thinpool data-sata-pool data-sata
```

Then register `data-sata` as a storage pool in Proxmox (Datacenter → Storage → Add → LVM-Thin).

### 3. Migrate Longhorn worker disks to SATA SSD

The Longhorn data disks (`virtio2`) on both workers are currently ZFS zvols on the NVMe. Moving them to `data-sata` separates Longhorn I/O from backup I/O — the two workloads that caused the original Sunday crashes.

Steps:
1. Update `terraform.tfvars` — change `datastore_id` for `virtio2` on both workers to `data-sata`
2. Apply Terraform (this recreates the disk, Longhorn will rebuild replicas from the surviving node)
3. In Longhorn: once new disks are healthy, remove the old NVMe-backed disks from each node

### 4. Restart worker VMs to apply RAM reduction

After Terraform applies the 6 GB memory change, worker VMs need a restart to pick up the new allocation. Coordinate with Longhorn — do one worker at a time so replicas remain healthy.

### 5. Long-term: upgrade to 64 GB RAM

The Ryzen 5 5600G supports up to 64 GB DDR4 (2 slots). A 2×32 GB DDR4 kit would provide permanent headroom, eliminating all of the above constraints. Currently deferred due to DDR4 pricing.
