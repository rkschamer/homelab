# Architecture Review — 2026-09-03

A review of whether the current topology (1 control plane + 2 workers on a single
Proxmox host, Longhorn with 2 replicas) is the right shape for this homelab, given
that memory/disk incidents keep recurring roughly every 30 days and buying more RAM
is not an option.

Companion to [memory-situation.md](memory-situation.md), which is the incident log.
This document is the structural analysis and the remediation plan.

## Summary

| Question | Answer |
|---|---|
| Keep Kubernetes? | **Yes.** Nothing in either incident traces to k8s. NetworkPolicies, GitOps and SealedSecrets are the parts that work. |
| Keep Longhorn? | **Yes — at one replica.** Snapshots and backups are the value. Replication is a no-op on this hardware. |
| Keep two workers? | **No.** ~2.3 GB of duplicated per-node overhead buys an HA property no service in the cluster has. |
| Root cause of recurrence? | Not RAM scarcity. Three mechanisms: no kubelet reservation, an OOM handler that cannot select any limited cgroup, and nothing that ever reclaims disk. |

## Method and confidence

Derived from the committed repository state: `terraform/`, `talos/`, `flux/`, `docs/`
and `git log`. **No live cluster access** was available during the review — no
`kubectl` or `talosctl` binary in the environment.

- **Structural findings** (what is or is not in the manifests) are verified.
- **Runtime figures** (per-node overhead, working sets) are estimates derived from the
  manifests plus the RSS numbers recorded in `memory-situation.md`. Each is paired with
  the command that confirms it — see [Verification](#verification).

---

## Findings

### 1. No kubelet memory reservation — nodes starve instead of evicting

`terraform/talos.tf` patches `machine.kubelet` only to add the Longhorn bind mount.
There is no `extraConfig`, therefore no `systemReserved`, no `kubeReserved`, and the
stock `evictionHard` of `memory.available<100Mi`.

Two consequences:

- **Allocatable ≈ capacity.** The scheduler believes it can hand out nearly all 8 GB
  to pods, while Talos, containerd, the kubelet and the kernel still need theirs.
- **Eviction arms far too late.** On a node whose largest tenants are Go heaps growing
  in hundreds of megabytes, 100 MB free is long past the point of no return. The
  2026-07-22 log caught worker-1 at `MemAvailable ~822 MB of 6844 MB` and *already*
  `NotReady`.

The kubelet's eviction manager is the correct tool for this: it selects a victim by
priority and QoS, terminates it gracefully, and the node survives. It never gets to
run. This is why incidents end in a wedged node needing a manual reboot rather than
one restarted pod.

Note that Talos does place its own services in separate `system` and `podruntime`
cgroups outside `kubepods`, which is why the kubelet process itself is not killed
outright — but it is still starved of the memory it needs to post node status.

### 2. The Talos OOM handler cannot select any cgroup that has a memory limit

This is the mechanism behind the 498 SIGKILLs in 7.5 minutes on 2026-07-22.

Talos v1.12+ ships a PSI-based userspace OOM handler (enabled by default). Its
default `cgroupRankingExpression` is:

```
memory_max.hasValue() ? 0.0 :
  {Besteffort: 1.0, Burstable: 0.5, Guaranteed: 0.0, Podruntime: 0.0, System: 0.0}[class]
  * double(memory_current.orValue(0u))
```

The guard evaluates first: **any cgroup with `memory.max` set scores 0.0 and is never
selected.** This is not about QoS class — it is about the presence of a limit.

`memory-situation.md` attributes the churn to "the *protected* Burstable tenants
(Prometheus, Loki), which the reaper won't touch". The real rule is narrower:
Prometheus and Loki were immune because they carry `limits.memory`, not because they
are Burstable. The only pods in scope were those setting no limit at all —
`cilium-envoy`, `cilium-operator`, `metallb-frr-k8s`, `loki-canary`, `traefik`. The
handler killed those repeatedly because killing them could never free the memory that
was actually held.

Diligently setting limits on every workload is precisely what rendered the reaper
useless.

### 3. Nothing in the stack reclaims disk space

Three layers each retain freed blocks, and there is no job releasing any of them.

**Longhorn never trims automatically.** Per Longhorn's documentation, it does not
issue TRIM/UNMAP on its own, so a volume's actual size only grows — Prometheus
expiring a TSDB block or Loki dropping a chunk frees nothing at the Longhorn layer.
Longhorn provides a `filesystem-trim` RecurringJob task for exactly this;
`flux/infrastructure/config/longhorn/recurring-jobs.yaml` has no such job.

**Snapshot chains are deep on the worst-suited volumes.** `hourly-snapshot` retains 84
on every `default`-group volume. `monitoring-snapshot` retains 28 on the Prometheus
and Loki volumes — two 20 Gi volumes that rewrite most of their contents daily. Each
retained snapshot pins the blocks live at that moment. Everything is then doubled by
`numberOfReplicas: 2`.

**LUKS swallows the discards.** The Longhorn data disk is LUKS2-encrypted via
`UserVolumeConfig` in `talos/manifests/talos-worker-*/longhorn.yaml`. dm-crypt drops
discard requests unless the device is opened with `--allow-discards`, and Talos v1.13
exposes no such option — `allowDiscards` arrives in v1.14 (currently beta). So even
when the filesystem frees blocks, they never reach the LVM-thin pool. `discard = on`
in `nodes.tf` and `issue_discards = 1` in `lvm.conf` are both correct settings that
are blocked one layer above.

Net effect: thin-pool consumption from the two 264 GB Longhorn LVs only ever
increases, toward their full provisioned size.

### 4. The two-worker topology provides no availability

The original goal was to update one worker while the other serves traffic. Every
workload in the cluster is a single replica on a ReadWriteOnce volume:

| Workload | Replicas | Volume | Survives a drain? |
|---|---|---|---|
| **Traefik** (the ingress itself) | 1 | RWO, `Recreate` | No |
| Authelia | 1 | RWO Longhorn | No |
| Vaultwarden | 1 | RWO Longhorn | No |
| Pi-hole + Unbound | 1 | RWO Longhorn | No |
| Paperless-ngx + Redis | 1 | RWO Longhorn | No |
| Prometheus / Loki / Grafana / Alertmanager | 1 | RWO Longhorn | No |
| SiYuan, DoneTick, Karakeep, OrcaSlicer | 1 | RWO Longhorn | No |
| CrowdSec LAPI + AppSec | 1 | RWO | No |
| Snowflake proxy | 1 | none | Yes |

A ReadWriteOnce volume must detach and reattach, and the pod must restart, wherever it
lands. Traefik makes the outage total: when it moves, everything behind it goes dark
regardless of where the backends are scheduled.

This was already documented implicitly when the upstream `KubeMemoryOvercommit` rule
was disabled in `flux/monitoring/prometheus-release.yaml` with the note that the
cluster *"cannot tolerate node failure by design"*. That is the accurate reading. The
second worker is not buying availability; it is buying a second copy of the per-node
tax.

### 5. Longhorn replication is a no-op on this hardware

`docs/proxmox.md` places every VM disk on `local-lvm` — LVM-thin on the single 1 TB
NVMe. Both Longhorn replicas of every volume are therefore files on the same physical
device. The failure that replication exists to survive (loss of the storage device) is
the one it cannot survive.

What 2-way replication does protect against: one worker's LUKS volume or ext4
corrupting independently of the other.

What it costs:

- 2× write amplification to a shared NVMe
- 2× snapshot space and 2× backup read IO
- A second instance-manager holding a replica process per volume
- Replica traffic across the VXLAN tunnel between workers

Real durability comes from the nightly Longhorn backup, which is unaffected by the
replica count. See [the separate finding below](#separate-finding--backups-have-one-target-not-two)
for a caveat on where those backups actually land.

---

## Memory accounting

### Per-worker fixed cost (estimated)

| Component | Estimated RSS |
|---|---|
| Talos base — kernel, machined, containerd, kubelet, apid, trustd | 600–800 MB |
| cilium-agent + cilium-envoy, with host firewall and Hubble | 400–700 MB |
| Longhorn — manager, instance-manager, csi-plugin, engine-image | 400–800 MB |
| fluent-bit + node-exporter | ~150 MB |
| metallb speaker + frr-k8s | ~100 MB |
| **Total, before any application pod** | **1.7–2.5 GB** |

Run twice, roughly 4.5 GB of the 16 GB of worker RAM is consumed before Vaultwarden
starts. Figures below use 2.3 GB as the midpoint.

### Host allocation, 27 GB visible

| | CP | worker-1 | worker-2 | Other VMs + PVE | Unallocated |
|---|---|---|---|---|---|
| Today | 6 GB | 8 GB | 8 GB | ~3 GB | ~2 GB |
| One worker | 6 GB | 14 GB | — | ~3 GB | ~4 GB |

### Memory that actually reaches a pod

| | Per-node overhead | Available to pods |
|---|---|---|
| Today (2 × 8 GB) | 2 × 2.3 GB = 4.6 GB | 11.4 GB, split into two 5.7 GB pools |
| One worker (1 × 14 GB) | 1 × 2.3 GB | 11.7 GB, one pool |

Consolidating yields marginally **more** usable pod memory in a single contiguous pool
**and** returns 2 GB to the host. It also ends node-level fragmentation — today a 3 GB
pod cannot schedule even when 5 GB is free cluster-wide, because it is 2.5 GB on each
side — and retires the Prometheus/Loki anti-affinity workaround.

---

## Ranked changes

Ordered by incident-recurrence impact per unit of work. Tier 0 is small YAML and
should land before anything structural.

### Tier 0.1 — Reserve memory and arm eviction

**~20 min, one reboot per node. Highest-value change on this list.**

This creates no memory. It converts "node wedges, needs a manual reboot, ~100 alerts"
into "one pod is evicted, Flux restarts it". With `enforceNodeAllocatable` at its
default of `["pods"]`, the kubelet also caps the whole `kubepods` cgroup at
allocatable, so an overrun kills a pod rather than starving the kubelet.

In `terraform/talos.tf`, inside the worker `kubelet = merge(...)` block alongside the
existing `extraMounts`:

```hcl
extraConfig = {
  systemReserved = { cpu = "200m", memory = "512Mi" }
  kubeReserved   = { cpu = "200m", memory = "512Mi" }
  evictionHard   = { "memory.available" = "300Mi", "nodefs.available" = "10%" }
  evictionSoft   = { "memory.available" = "800Mi" }
  evictionSoftGracePeriod   = { "memory.available" = "2m" }
  evictionMaxPodGracePeriod = 60
}
```

Expect `KubeMemoryOvercommit` to start firing — allocatable drops by ~1.3 GB per node
and the ratio is now telling the truth. Raise the threshold once, deliberately, rather
than reverting the reservation.

Talos rejects some kubelet keys (authentication/authorization, cgroup paths, ports).
Confirm what actually landed:

```bash
talosctl -n 10.10.20.21 read /etc/kubernetes/kubelet.yaml
```

### Tier 0.2 — Stop snapshotting and backing up disposable data

**~30 min, Flux only. Removes the 02:00–03:00 IO storm.**

`docs/backup.md` rates Prometheus "Low — metrics history only" and Loki "Low — log
history only". Both are nonetheless in the `daily-backup` group, so ~40 Gi of
throwaway data is read off disk and shipped to the NAS nightly, on volumes already
carrying 28 retained snapshots each. Wave 1 of the 2026-07-22 incident is this window.

In `flux/infrastructure/config/longhorn/recurring-jobs.yaml`:

```yaml
# daily-backup — drop the monitoring group
  groups:
    - default
#   - monitoring        <- remove

# hourly-snapshot — 84 is 7 days at 2h; daily backups already cover 30 days
  retain: 24            # was 84

# monitoring-snapshot — or delete the job outright
  retain: 4             # was 28
```

Add the missing trim job — nothing in Longhorn reclaims space on its own:

```yaml
---
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: filesystem-trim
  namespace: longhorn-system
spec:
  cron: "0 4 * * *"   # well clear of the 02:00-03:00 window
  task: filesystem-trim
  groups:
    - default
    - monitoring
  retain: 0           # ignored for trim tasks; adjust if the webhook objects
  concurrency: 1
```

And in `flux/infrastructure/releases/longhorn-release.yaml` under `defaultSettings`:

```yaml
removeSnapshotsDuringFilesystemTrim: true
```

**Second-order benefit:** Longhorn models every snapshot and backup as a custom
resource. Roughly 840 snapshot CRs plus 30 days of backup CRs are live objects in etcd
that the apiserver holds in its watch cache. Cutting retention cuts control-plane
apiserver memory too — worth re-checking against open item 1 in `memory-situation.md`
before concluding anything is abnormal there.

### Tier 0.3 — Longhorn to one replica

**~30 min plus rebuild wait. Halves write IO and space.**

Rationale in [finding 5](#5-longhorn-replication-is-a-no-op-on-this-hardware).

In `flux/infrastructure/releases/longhorn-release.yaml`:

```yaml
persistence:
  defaultClassReplicaCount: 1
defaultSettings:
  defaultReplicaCount: "1"
```

Then set `numberOfReplicas: "1"` in every `pv.yaml` under `csi.volumeAttributes`, and
update the template in [longhorn.md](longhorn.md#pv-manifest-template).

Those attributes only apply at provision time, so existing volumes need changing
directly:

```bash
kubectl -n longhorn-system get volumes.longhorn.io -o name \
  | xargs -I{} kubectl -n longhorn-system patch {} --type=merge \
      -p '{"spec":{"numberOfReplicas":1}}'
```

Pod mobility is unaffected: the Longhorn engine runs beside the pod and reaches its
replica over TCP, so a single-replica volume still attaches from either node.

### Tier 1 — Consolidate to one worker at 14 GB

**Half a day. Structural. ~2 GB returned to the host.**

Do Tier 0.3 first — with `defaultReplicaCount` still at 2, removing a node leaves
every volume permanently degraded.

1. Longhorn UI → Node → worker-2 → disable scheduling; wait for replicas to evacuate
2. `kubectl drain talos-worker-2 --ignore-daemonsets --delete-emptydir-data`
3. `kubectl delete node talos-worker-2`
4. Remove the `talos-worker-2` block from `terraform/terraform.tfvars`
5. Raise `talos-worker-1` memory to `14336`
6. `terraform apply`, then `talosctl -n 10.10.20.21 reboot`
7. Delete `talos/manifests/talos-worker-2/`

Afterwards, remove the `podAntiAffinity` blocks from `prometheus-release.yaml` and
`loki-release.yaml`. They are no-ops on one node, and leaving them hides why they
existed.

Also re-check the Cilium host-firewall policies in
`flux/infrastructure/config/network-policies/host-firewall-policies.yaml` — they
select on `node-role.kubernetes.io/*` labels.

**What this gives up, stated honestly:** a worker reboot becomes a full cluster outage
of a few minutes rather than a partial one. Per [finding 4](#4-the-two-worker-topology-provides-no-availability),
the current partial outage is already total the moment Traefik moves.

### Tier 1.5 — Move the Longhorn data disk to the idle SATA SSD

**~1 hour, zero cost. Separates storage IO from the boot device.**

The 512 GB SATA SSD is already installed and configured as an unused `data-sata` thin
pool (see [ext4-migration.md](ext4-migration.md)). Meanwhile all Longhorn traffic,
every VM system disk, PVE root and PVE swap contend for the one NVMe. That contention
is the most likely explanation for the 3.5 s hypervisor stall that made worker-1 miss
its kubelet heartbeat at ~01:00 on 2026-07-01.

One 264 GB Longhorn disk fits the ~500 GB pool comfortably, and PVE can move it live:

```bash
qm move-disk 220 virtio2 data-sata --delete 1
```

Then update `datastore_id` for the worker's `virtio2` disk in `terraform/nodes.tf` so
Terraform does not try to move it back.

SATA gives up sequential throughput against NVMe. For SQLite databases, a Prometheus
TSDB and Loki chunks that is not the binding constraint — contention is. It also frees
264 GB of thin allocation on the NVMe, which matters given
[finding 3](#3-nothing-in-the-stack-reclaims-disk-space): until Talos v1.14, that
pool's usage from the Longhorn LV only ever increases.

### Tier 2.1 — Drop Prometheus cardinality before migrating anything

**~1 hour, Flux only. Most of the VictoriaMetrics win, none of the migration risk.**

Prometheus memory tracks active series close to linearly. Empty selectors
(`serviceMonitorSelector: {}`, `podMonitorSelector: {}`) discover everything
cluster-wide — the right call for coverage, the expensive one for RAM. cAdvisor and
node-exporter alone contribute tens of thousands of series with no corresponding
dashboard.

In `flux/monitoring/prometheus-release.yaml`:

```yaml
kubelet:
  serviceMonitor:
    cAdvisorMetricRelabelings:
      - sourceLabels: [__name__]
        action: drop
        regex: 'container_(network_tcp_usage_total|network_udp_usage_total|tasks_state|memory_failures_total|blkio_device_usage_total)'
      - sourceLabels: [__name__]
        action: drop
        regex: 'container_(fs_.*|spec_.*)'
```

Measure with `prometheus_tsdb_head_series` before and after — that is the number which
predicts RSS.

### Tier 2.2 — VictoriaMetrics, then VictoriaLogs

**1–2 days, two separate migrations. ~1 GB of tenant RSS.**

Open item 4 in `memory-situation.md` is correct and the analysis there holds. Ranked
below the items above because it is the most work and no longer the largest single win
once Tier 0 and Tier 1 land.

The architectural reason it wins is worth stating precisely: Prometheus holds the head
block, series index and recent chunks in the Go heap, which the kernel cannot reclaim
under pressure and can only OOM. `vmsingle` keeps hot data in page cache the kernel
already knows how to evict, so the same workload degrades instead of dying — exactly
the property this host needs.

One addition to the existing plan: do this **after** the consolidation, so the named
PVs and `recurring-job-group` labels are not re-pointed twice.

### Tier 3 — Talos v1.14 closes the discard gap

**Watch only, until released.**

Two features land together in v1.14 (currently beta):

- **`allowDiscards`** on volume encryption — passes TRIM through LUKS to the
  underlying device. Disabled by default; would be set on the Longhorn
  `UserVolumeConfig`.
- **`FilesystemTrimConfig`** — Talos periodically trims mounted filesystems itself,
  weekly by default. Today Talos runs no `fstrim` at all, so even with discards allowed
  nothing would trigger them.

Together these are what finally lets deleted blocks travel from a Longhorn volume back
to the LVM-thin pool. Until then, the Tier 0.2 trim job reclaims space *inside* the
Longhorn volumes, which is the layer the node-level disk alerts watch.

**Noted but deliberately not recommended yet:** Kubernetes 1.36 (the running version)
adds tiered Memory QoS — `memory.high` from limits, `memory.low` from requests — so
Burstable pods are throttled and reclaimed rather than OOM-killed. Correct shape for
this host, but alpha and off by default. Not something to enable on a cluster being
stabilised.

### Tier 3+ — Make the OOM handler able to act

**Optional backstop.**

If Tier 0.1 works, this never runs. But the current default guarantees the handler is
useless precisely when needed — see
[finding 2](#2-the-talos-oom-handler-cannot-select-any-cgroup-that-has-a-memory-limit).

An `OOMConfig` document can replace `cgroupRankingExpression` so cgroups over their
limit become selectable — ranking by overage rather than exempting on the presence of
`memory.max`. Treat it as a backstop behind kubelet eviction, not a substitute. The
expression language is CEL, and the failure mode of getting it wrong is killing the
wrong thing. Read the v1.13 OOM documentation first.

---

## Separate finding — backups have one target, not two

Not an optimization. A gap found while reading the Longhorn config.

Commit `2462a38` (2026-06-25, *"fix(longhorn): remove S3 backup target temporarily"*)
dropped `backup-target-s3.yaml` from
`flux/infrastructure/config/longhorn/kustomization.yaml`. It is still out. The file
remains in the repo but nothing references it, so Flux never applies it, and every
`daily-backup` job writes to the `default` BackupTarget — the Synology NFS share.

[backup.md](backup.md) meanwhile describes two live destinations:

> - **S3 (Garage):** `s3://longhorn-bucket@garage/` — `daily-backup` job at 02:00
> - **NFS:** `nfs://192.168.123.5:/volume1/backups/longhorn` — `daily-backup-nfs` job at 02:30

Neither statement holds. There is no `daily-backup-nfs` RecurringJob, and Garage is
receiving nothing.

Practical position: every Longhorn backup — Vaultwarden, Authelia, Paperless — lives
on the NAS and nowhere else. Worth deciding on purpose. Re-adding the S3 target to the
kustomization is a one-line change; leaving it out and correcting `backup.md` is
equally valid. Believing there are two copies when there is one is not.

---

## What not to change

| Component | Verdict |
|---|---|
| Kubernetes | Keep. Nothing in either incident traces to k8s. Zone isolation is enforced by namespace label and Cilium policy, not node placement, so it survives consolidation untouched. |
| Cilium + host firewall + Hubble | Keep. This is the reason for running k8s at all. Re-check host-firewall policies after removing worker-2 (they select on `node-role.kubernetes.io/*`). |
| Flux / GitOps | Keep. The reason this review was possible from the repository alone. |
| Longhorn | Keep at one replica. Replacing it with local-path means rebuilding snapshots, S3/NFS backup and a working 200-line restore runbook. One replica captures most of the cost saving at almost none of the risk. |
| Talos | Keep. Immutable, small, and the OOM handler is a genuine asset once configured to be one. |
| Separate control-plane VM | Keep. It is also the bastion and router between `vmbr0` and `vmbr1`; collapsing to a single node would entangle that with etcd and workload scheduling for perhaps 1 GB. |

---

## Verification

Runtime figures in this document are estimates. Confirm before acting on them.

```bash
# Per-node overhead: node total vs. sum of its pods — the gap is the overhead
kubectl top node
kubectl top pod -A --sort-by=memory

# What Talos itself sees
talosctl -n 10.10.20.21 memory
talosctl -n 10.10.20.21 cgroups --preset=memory

# Longhorn actual space consumption vs. nominal
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,SIZE:.spec.size,ACTUAL:.status.actualSize,REPLICAS:.spec.numberOfReplicas

# Snapshot CR count (etcd/apiserver load)
kubectl -n longhorn-system get snapshots.longhorn.io --no-headers | wc -l

# Prometheus series count — predicts RSS
# (Grafana Explore) prometheus_tsdb_head_series

# Where backups are actually landing
kubectl -n longhorn-system get backuptarget
kubectl -n longhorn-system get backupvolume
```

## Change tracking

| Change | Tier | Status |
|---|---|---|
| kubelet `systemReserved` / `kubeReserved` / eviction thresholds | 0.1 | Not started |
| Remove monitoring volumes from `daily-backup` | 0.2 | Not started |
| Reduce snapshot retention (84 → 24, 28 → 4) | 0.2 | Not started |
| Add `filesystem-trim` RecurringJob | 0.2 | Not started |
| `removeSnapshotsDuringFilesystemTrim: true` | 0.2 | Not started |
| Longhorn `numberOfReplicas` 2 → 1 (chart, PVs, existing volumes) | 0.3 | Not started |
| Remove worker-2; worker-1 to 14 GB | 1 | Not started |
| Remove Prometheus/Loki anti-affinity | 1 | Not started |
| Move Longhorn data disk to `data-sata` | 1.5 | Not started |
| Prometheus cAdvisor metric drops | 2.1 | Not started |
| Prometheus → VictoriaMetrics | 2.2 | Not started |
| Loki → VictoriaLogs | 2.2 | Not started |
| Talos v1.14 — `allowDiscards` + `FilesystemTrimConfig` | 3 | Blocked on release |
| Custom `OOMConfig` ranking expression | 3+ | Optional |
| Decide S3 backup target: re-add, or correct `backup.md` | — | Not started |

## References

Internal:

- [memory-situation.md](memory-situation.md) — incident log and mitigation history
- [proxmox.md](proxmox.md) — host hardware, storage layout, VM profile
- [longhorn.md](longhorn.md) — named PV convention, restore procedures
- [backup.md](backup.md) — what must be backed up and why
- [ext4-migration.md](ext4-migration.md) — NVMe/SATA layout, thin pool sizing

External:

- [Talos OOM handler (v1.13)](https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/system-configuration/oom)
- [Talos cgroups resource analysis](https://docs.siderolabs.com/talos/v1.13/build-and-extend-talos/cluster-operations-and-maintenance/cgroups-analysis)
- [Talos v1.14.0-beta.0 changelog](https://github.com/siderolabs/talos/discussions/13868) — `allowDiscards`, `FilesystemTrimConfig`
- [Longhorn — Trim Filesystem](https://longhorn.io/docs/1.12.1/nodes-and-volumes/volumes/trim-filesystem/)
- [Longhorn — Scheduling Backups and Snapshots](https://longhorn.io/docs/1.12.1/snapshots-and-backups/scheduling-backups-and-snapshots/)
- [Longhorn — Space consumption guideline](https://longhorn.io/kb/space-consumption-guideline/)
- [Kubernetes v1.36 — Memory QoS tiered protection](https://kubernetes.io/blog/2026/04/29/kubernetes-v1-36-memory-qos-tiered-protection/)
- [Kubernetes — Reserve Compute Resources for System Daemons](https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/)
