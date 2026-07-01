# Proxmox Host Memory Situation

## Hardware

- CPU: AMD Ryzen 5 5600G (6 cores / 12 threads), max supported RAM: 64 GB DDR4
- RAM installed: 32 GB (27 GB visible to OS — remainder reserved by BIOS/iGPU)
- Storage (post-migration): NVMe on ext4/LVM, 512 GB SATA SSD as `data-sata` spare pool

## Status

- Post-migration (2026-06-23): swap-on-zvol deadlock eliminated, ZFS removed.
- Post-incident (2026-07-01): control-plane VM bumped from 4 → 6 GB, workers rolled
  back from 8 → 6 GB. See "Incident: 2026-07-01" below.

## Current VM Memory Allocation

| Consumer | RAM |
|---|---|
| talos-controlplane-1 | 6 GB (bumped from 4 GB after apiserver OOM) |
| talos-worker-1 | 6 GB (rolled back from 8 GB) |
| talos-worker-2 | 6 GB (rolled back from 8 GB) |
| Home Assistant + other VMs | ~2–4 GB |
| PVE overhead | ~1–2 GB |
| **Total demand** | **~21–24 GB on a 27 GB host** |

The host now has ~3 GB of genuine slack. `pve/swap` (LVM LV on ext4, not zvol) exists
as a safety valve — safe under pressure, unlike the pre-migration zvol swap.

## Incident: 2026-07-01 — apiserver OOM on CP

### What happened

Two waves of alerts:

- **~01:00 UTC:** worker-1 kernel logged `clocksource: Long readout interval,
  skipping watchdog check: cs_nsec: 3547019700` — the VM was paused ~3.5 s by the
  hypervisor. Kubelet health check timed out, worker briefly NotReady. Consistent
  with host-side pressure from the nightly backup job.
- **~08:31 UTC:** kernel OOM inside the CP VM killed kube-apiserver:
  ```
  Out of memory: Killed process 3460 (kube-apiserver)
    total-vm:3365048kB anon-rss:2002928kB
    oom-kill: constraint=CONSTRAINT_NONE ... global_oom
  ```
  `global_oom` means the entire VM was out of memory, not a container cgroup limit.
  Talos's PSI-based OOMController had been firing every ~500 ms for ~3 min before
  the kernel intervened, but reported `victim processes: []` — it was trying to
  reap phantom besteffort cgroups that had no live processes, so it couldn't free
  anything. The kernel eventually picked apiserver because it had the largest
  reclaimable footprint (anon-rss ~2 GB).

### Root cause

The 4 GB CP allocation was too tight for the actual working set (Talos + etcd +
apiserver + controller-manager + scheduler + kubelet + cilium-agent + kernel).
Without swap, anonymous RSS from apiserver's Go heap could not be reclaimed — the
kernel's only lever under pressure was OOM-kill.

The dashboard "1 GB free" reading was misleading: what looks like free memory is
mostly page cache, which cannot substitute for anonymous pages when a Go process
grows its heap. `MemAvailable` (not `MemFree`) is the number that matters, and it
was near zero at the moment of the kill.

### Fix applied

- **CP: 4 GB → 6 GB** (`terraform/terraform.tfvars`).
- **Workers: 8 GB → 6 GB** (rolled back the 2026-06-23 bump to free host RAM for
  the CP without exceeding the total envelope).
- **`KubeMemoryOvercommit` alert relaxed** to fire at >90% requested/allocatable
  instead of the upstream N-1 rule. The default rule effectively asks "can one
  worker hold all pods if the other dies?" which is impractical on a 2-worker
  homelab. See `flux/monitoring/prometheus-release.yaml`.

Apply order to minimize disruption:
1. Push the Flux change first so the alert threshold updates before workers shrink.
2. `terraform apply` to update VM configs.
3. `talosctl reboot` each node in sequence (workers one at a time, then CP), waiting
   for cluster health and Longhorn to stabilize between each.

## Swap Posture

Swap was disabled cluster-wide during the 2026-05 incident and remains disabled on
all Talos nodes (`talos/manifests/*/swap.yaml` removed, virtio1 disks removed in
`terraform/nodes.tf`). This is the stable state.

The PVE host itself keeps its installer-created `pve/swap` LV. Unlike the old ZFS
zvol swap, an LVM swap LV on ext4 is a plain block device with no deadlock risk.
With `vm.swappiness=10` it only activates under genuine memory pressure.

```
# /etc/sysctl.d/99-proxmox.conf
vm.swappiness=10
```

## Mitigations History

| Fix | Status |
|---|---|
| ZFS → ext4 migration (removed ARC + zvol swap deadlock) | Done (2026-06-23) |
| `vm.swappiness=10` on host | Done |
| Longhorn `concurrentReplicaRebuildPerNodeLimit` raised to 5 | Done (in HelmRelease) |
| PVE backup bandwidth limit set to 50 MiB/s | Done |
| PVE backup fleecing enabled on local pool | Done |
| CP 4 → 6 GB, workers 8 → 6 GB | Done (2026-07-01, needs apply + reboot) |
| `KubeMemoryOvercommit` alert threshold relaxed to 0.9 | Done (2026-07-01, needs push) |

## Open Items

### 1. Watch CP memory after the bump

If apiserver RSS still climbs toward 2 GB in steady state on the 6 GB CP, that
points to something abnormal — a watch-cache leak, an operator hammering LIST
requests, or a large etcd DB. Worth investigating rather than just adding more RAM.

Useful checks after cluster access is restored:

```bash
# apiserver working set
kubectl top pod -n kube-system -l component=kube-apiserver

# etcd DB size
kubectl exec -n kube-system etcd-talos-controlplane-1 -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table
```

### 2. Backup schedule review

Wave 1 of the incident lined up with typical backup hours. Verify:
- `cat /etc/pve/jobs.cfg` — what runs at ~01:00?
- Datacenter → Backup → Bandwidth limit still 50 MiB/s?
- Consider staggering VMs across different hours if all-at-once causes host stalls.

### 3. Longhorn instance-manager memory requests

The bulk of the workers' pod memory requests is Longhorn instance-manager, which
scales per replica. If `defaultInstanceManagerCPU`/`memory` is reducible in the
Longhorn HelmRelease, that would give room to grow the workers back to 8 GB later
without triggering the overcommit alert.

### 4. Long-term: upgrade to 64 GB RAM

The Ryzen 5 5600G supports up to 64 GB DDR4 (2 slots). A 2×32 GB DDR4 kit would
provide permanent headroom, eliminating the whole class of overcommit failures.
Currently deferred due to DDR4 pricing.
