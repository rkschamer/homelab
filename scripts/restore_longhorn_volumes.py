#!/usr/bin/env python3
"""Restore Longhorn volumes from S3 backups after a cluster rebuild.

 Three restore modes are handled automatically based on whether the PVC has a
named PV manifest committed to Git:

NAMED PV (services with pv.yaml in Git — vaultwarden, siyuan, pi-hole, etc.)
  The Longhorn volume is restored with the exact name from the Git PV manifest
  (e.g. "pv-vaultwarden-data"). Flux owns the PV and PVC objects — the script
  only restores the Longhorn volume. The restored volume name MUST match the
  volumeHandle in the PV manifest exactly, or the PVC will stay Pending.

  Workflow:
    flux suspend kustomization --all
    scripts/restore_longhorn_volumes.py plan
    scripts/restore_longhorn_volumes.py restore --all --apply
    # wait for Longhorn restores to complete, then:
    flux resume kustomization --all
    # Flux creates PV/PVC objects; they bind immediately since volumeHandle matches

HELM-MANAGED PVC (crowdsec, traefik, prometheus, alertmanager, grafana, loki)
  The Helm chart creates and names the PVC. The script restores the Longhorn
  volume using the original UUID-based PV name from the backup metadata so the
  existing PVC (already created by Helm) can bind to it. Pass --helm to enable.

  Workflow:
    # Let Flux install the Helm charts first (creates empty PVCs)
    scripts/restore_longhorn_volumes.py restore --namespace crowdsec --apply --helm --replace --scale-workloads
    # Repeat per namespace as needed

LEGACY / UNKNOWN
  For any backup not covered by the above, the script falls back to the
  original behaviour: create a "restored-<pv>" PV and PVC. The PVC name and
  namespace come from the backup's KubernetesStatus label.

When multiple BackupVolumes target the same namespace/PVC (older + newer
generations of the same logical volume), only the most recent backup is used.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Optional

LONGHORN_NS = "longhorn-system"
FS_TYPE = "ext4"
NUMBER_OF_REPLICAS = 2
RESTORE_TIMEOUT_S = 1800
SCALE_ANNOTATION = "homelab.local/pre-restore-replicas"
VOL_PREFIX = "r-"
PV_PREFIX = "restored-"
LONGHORN_MAX_VOL_NAME = 40

# Services whose PVCs are helm-managed (chart controls the PVC name).
# These use the original PV name from backup metadata as the restore target
# so the existing Helm-created PVC can bind to the restored volume.
HELM_MANAGED_NAMESPACES = {
    "crowdsec",
    "traefik",
    "monitoring",
}

# Git repo root — used to discover named PV manifests.
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr)


def warn(msg: str) -> None:
    log(f"WARN: {msg}")


def kubectl(*args: str, check: bool = True, stdin: Optional[str] = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["kubectl", *args],
        check=check,
        capture_output=True,
        text=True,
        input=stdin,
    )


def kubectl_json(*args: str) -> dict:
    return json.loads(kubectl(*args).stdout)


def kubectl_exists(*args: str) -> bool:
    return kubectl(*args, check=False).returncode == 0


def load_named_pv_map() -> dict[tuple[str, str], str]:
    """Scan all pv.yaml files in the Git repo and return a map of
    (namespace, pvc_name) -> longhorn_volume_name (= volumeHandle = PV name).

    Services that have a pv.yaml committed to Git use the named PV convention:
    the Longhorn volume name is fixed (e.g. "pv-vaultwarden-data") and must be
    used as the restore target so Flux-managed PV objects bind correctly.
    """
    import glob
    import re

    named: dict[tuple[str, str], str] = {}
    for pv_file in glob.glob(os.path.join(REPO_ROOT, "flux", "**", "pv.yaml"), recursive=True):
        try:
            with open(pv_file) as f:
                content = f.read()
        except OSError:
            continue
        # Parse each YAML document in the file
        for doc in content.split("\n---"):
            if "kind: PersistentVolume" not in doc:
                continue
            vh_match = re.search(r"volumeHandle:\s+(\S+)", doc)
            ns_match = re.search(r"claimRef:\s*\n\s+namespace:\s+(\S+)\s*\n\s+name:\s+(\S+)", doc)
            if vh_match and ns_match:
                namespace = ns_match.group(1)
                pvc_name = ns_match.group(2)
                volume_handle = vh_match.group(1)
                named[(namespace, pvc_name)] = volume_handle
    return named


@dataclass
class BackupTarget:
    bv_name: str             # BackupVolume CR name (e.g. authelia-data-4f2d961b)
    vol_name: str            # original Longhorn volume name (e.g. authelia-data)
    last_backup: str         # most recent backup snapshot id
    last_backup_at: str      # ISO timestamp of most recent backup
    size: str                # bytes, as string
    storage_class: str
    access_mode: str         # rwo / rwx
    pv_name: str             # original PV name from KubernetesStatus
    pvc_name: str
    pvc_namespace: str
    # Named PV volume handle from Git pv.yaml (set after load_named_pv_map lookup)
    named_volume_handle: str = ""

    @property
    def restore_mode(self) -> str:
        """One of: named_pv | helm_managed | legacy"""
        if self.named_volume_handle:
            return "named_pv"
        if self.pvc_namespace in HELM_MANAGED_NAMESPACES:
            return "helm_managed"
        return "legacy"

    @property
    def desired_volume_name(self) -> str:
        """The Longhorn volume name to restore into."""
        if self.restore_mode == "named_pv":
            # Must match the volumeHandle in the Git PV manifest exactly.
            return self.named_volume_handle
        if self.restore_mode == "helm_managed":
            # Restore into the original PV name so the Helm-created PVC binds.
            return self.pv_name or f"{VOL_PREFIX}{self.vol_name}"
        # Legacy: short prefix to stay within Longhorn's 40-char name limit.
        return f"{VOL_PREFIX}{self.vol_name}"

    @property
    def restored_pv(self) -> str:
        """Kubernetes PV name for legacy/helm_managed modes.
        Named PV mode does not create PV objects (Flux owns them).
        """
        if self.restore_mode == "helm_managed":
            return self.pv_name
        return f"{PV_PREFIX}{self.pv_name}"

    @property
    def k8s_access_mode(self) -> str:
        return "ReadWriteMany" if self.access_mode == "rwx" else "ReadWriteOnce"

    @property
    def has_k8s_metadata(self) -> bool:
        return bool(self.pvc_name and self.pvc_namespace)


def parse_backup_volume(bv: dict) -> BackupTarget:
    status = bv.get("status", {}) or {}
    labels = status.get("labels") or {}
    k8s_raw = labels.get("KubernetesStatus") or "{}"
    try:
        k8s = json.loads(k8s_raw)
    except json.JSONDecodeError:
        k8s = {}
    return BackupTarget(
        bv_name=bv["metadata"]["name"],
        vol_name=bv["spec"]["volumeName"],
        last_backup=status.get("lastBackupName") or "",
        last_backup_at=status.get("lastBackupAt") or "",
        size=str(status.get("size") or "0"),
        storage_class=status.get("storageClassName") or "longhorn",
        access_mode=labels.get("longhorn.io/volume-access-mode") or "rwo",
        pv_name=k8s.get("pvName") or "",
        pvc_name=k8s.get("pvcName") or "",
        pvc_namespace=k8s.get("namespace") or "",
    )


def list_backup_volumes() -> list[BackupTarget]:
    data = kubectl_json("get", "backupvolume", "-n", LONGHORN_NS, "-o", "json")
    targets = [parse_backup_volume(item) for item in data.get("items", [])]
    named_pv_map = load_named_pv_map()
    for t in targets:
        key = (t.pvc_namespace, t.pvc_name)
        if key in named_pv_map:
            t.named_volume_handle = named_pv_map[key]
    return targets


def backup_target_url() -> str:
    url = kubectl(
        "get", "backuptarget", "-n", LONGHORN_NS, "default",
        "-o", "jsonpath={.spec.backupTargetURL}",
    ).stdout.strip()
    return url.rstrip("/")


def dedupe_latest(targets: list[BackupTarget]) -> tuple[list[BackupTarget], list[BackupTarget]]:
    """Keep one target per (namespace, pvc); pick the one with the newest backup.

    Returns (kept, dropped) so the plan can show what was superseded.
    """
    grouped: dict[tuple[str, str], list[BackupTarget]] = {}
    no_meta: list[BackupTarget] = []
    for t in targets:
        if not t.has_k8s_metadata:
            no_meta.append(t)
            continue
        grouped.setdefault((t.pvc_namespace, t.pvc_name), []).append(t)

    kept: list[BackupTarget] = []
    dropped: list[BackupTarget] = []
    for items in grouped.values():
        items.sort(key=lambda t: t.last_backup_at, reverse=True)
        kept.append(items[0])
        dropped.extend(items[1:])
    return (kept + no_meta, dropped)


def apply_filters(targets: list[BackupTarget], args: argparse.Namespace) -> list[BackupTarget]:
    out = targets
    if args.volume:
        out = [t for t in out if t.bv_name == args.volume]
    if args.namespace:
        out = [t for t in out if t.pvc_namespace == args.namespace]
    return out


def human_size(n_str: str) -> str:
    try:
        n = int(n_str)
    except ValueError:
        return n_str
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f}{unit}" if unit != "B" else f"{n}{unit}"
        n /= 1024
    return f"{n:.1f}PB"


def find_restored_volume(t: BackupTarget) -> Optional[str]:
    """Find an existing restored Longhorn volume for this backup target.

    For named_pv mode, look up the exact volume name from the Git manifest.
    For other modes, search by the backup-volume label Longhorn sets automatically.
    """
    if t.restore_mode == "named_pv":
        exists = kubectl(
            "get", "volume.longhorn.io", "-n", LONGHORN_NS, t.named_volume_handle,
            "-o", "jsonpath={.metadata.name}", check=False,
        ).stdout.strip()
        return exists or None

    out = kubectl(
        "get", "volume.longhorn.io", "-n", LONGHORN_NS,
        "-l", f"backup-volume={t.vol_name}",
        "-o", "jsonpath={.items[*].metadata.name}",
        check=False,
    ).stdout.strip()
    candidates = [n for n in out.split() if n.startswith(VOL_PREFIX) or n.startswith(PV_PREFIX)]
    return candidates[0] if candidates else None


def pvc_status(t: BackupTarget) -> str:
    if not t.last_backup:
        return "NO_BACKUP"
    if not t.has_k8s_metadata:
        return "NO_K8S_METADATA"
    if not kubectl_exists("get", "pvc", "-n", t.pvc_namespace, t.pvc_name):
        if not kubectl_exists("get", "ns", t.pvc_namespace):
            return "NS_MISSING"
        return "PVC_MISSING"
    bound_pv = kubectl(
        "get", "pvc", "-n", t.pvc_namespace, t.pvc_name,
        "-o", "jsonpath={.spec.volumeName}", check=False,
    ).stdout.strip()
    if not bound_pv:
        return "PVC_UNBOUND"
    vh = kubectl(
        "get", "pv", bound_pv,
        "-o", "jsonpath={.spec.csi.volumeHandle}", check=False,
    ).stdout.strip()
    restored = find_restored_volume(t)
    if restored and vh == restored:
        return "ALREADY_RESTORED"
    return "PVC_EXISTS(empty)"


def cmd_plan(args: argparse.Namespace) -> int:
    targets = list_backup_volumes()
    kept, dropped = dedupe_latest(targets)
    kept = apply_filters(kept, args)

    fmt = "{:<52}  {:<48}  {:<24}  {:>8}  {:<12}  {}"
    print(fmt.format("BACKUP VOLUME", "TARGET PVC", "LAST BACKUP", "SIZE", "MODE", "STATUS"))
    print(fmt.format("-" * 52, "-" * 48, "-" * 24, "-" * 8, "-" * 12, "-" * 16))
    for t in sorted(kept, key=lambda x: (x.pvc_namespace, x.pvc_name, x.bv_name)):
        target_pvc = f"{t.pvc_namespace}/{t.pvc_name}" if t.has_k8s_metadata else "(no k8s metadata)"
        print(fmt.format(
            t.bv_name,
            target_pvc,
            t.last_backup or "-",
            human_size(t.size),
            t.restore_mode,
            pvc_status(t),
        ))

    if dropped:
        print()
        print(f"# Skipped {len(dropped)} older backup(s) superseded by newer ones for the same PVC:")
        for t in dropped:
            print(f"#   {t.bv_name}  ->  {t.pvc_namespace}/{t.pvc_name}  ({t.last_backup_at})")
    return 0


def find_workload(namespace: str, pod_name: str) -> Optional[str]:
    """Walk owner refs from a pod to its Deployment/StatefulSet/DaemonSet. Returns 'Kind/name'."""
    pod = kubectl(
        "get", "pod", "-n", namespace, pod_name, "-o", "json", check=False,
    )
    if pod.returncode != 0:
        return None
    owners = json.loads(pod.stdout).get("metadata", {}).get("ownerReferences") or []
    if not owners:
        return None
    owner = owners[0]
    kind, name = owner["kind"], owner["name"]
    if kind == "ReplicaSet":
        rs = kubectl(
            "get", "rs", "-n", namespace, name, "-o", "json", check=False,
        )
        if rs.returncode == 0:
            rs_owners = json.loads(rs.stdout).get("metadata", {}).get("ownerReferences") or []
            if rs_owners:
                return f"{rs_owners[0]['kind']}/{rs_owners[0]['name']}"
    return f"{kind}/{name}"


def workloads_using_pvc(namespace: str, pvc: str) -> list[str]:
    pods = kubectl_json("get", "pods", "-n", namespace, "-o", "json").get("items", [])
    workloads: list[str] = []
    seen: set[str] = set()
    for pod in pods:
        for vol in pod.get("spec", {}).get("volumes", []) or []:
            pvc_ref = (vol.get("persistentVolumeClaim") or {}).get("claimName")
            if pvc_ref != pvc:
                continue
            wl = find_workload(namespace, pod["metadata"]["name"])
            if wl and wl not in seen:
                seen.add(wl)
                workloads.append(wl)
            break
    return workloads


def scale_workload(namespace: str, workload: str, replicas: int, apply: bool) -> None:
    log(f"  SCALE {namespace}/{workload} -> {replicas}")
    if not apply:
        return
    kubectl("scale", "-n", namespace, workload, f"--replicas={replicas}")


def wait_for_restore(volume_name: str, apply: bool) -> None:
    log(f"  waiting for restore of {volume_name}...")
    if not apply:
        return
    deadline = time.time() + RESTORE_TIMEOUT_S
    while time.time() < deadline:
        vol = kubectl(
            "get", "volume.longhorn.io", "-n", LONGHORN_NS, volume_name,
            "-o", "json", check=False,
        )
        if vol.returncode != 0:
            log(f"    volume {volume_name} not found yet, waiting...")
            time.sleep(3)
            continue
        status = (json.loads(vol.stdout).get("status") or {})
        state = status.get("state") or "?"
        restore_required = status.get("restoreRequired")
        restore_initiated = status.get("restoreInitiated")
        rs = status.get("restoreStatus") or []
        # Per-replica progress (Longhorn reports one entry per replica during restore).
        progress = ",".join(str(r.get("progress", "?")) for r in rs) if rs else "-"
        log(f"    state={state} restore_initiated={restore_initiated} "
            f"restore_required={restore_required} progress=[{progress}]")
        # Restore is complete when Longhorn flips restoreRequired back to false
        # after restoreInitiated has been true and the volume reaches a stable state.
        if restore_initiated and restore_required is False and state in ("detached", "attached"):
            log(f"    restore complete (state={state})")
            return
        time.sleep(5)
    warn(f"timeout waiting for {volume_name} restore")


def apply_yaml(manifest: str, apply: bool) -> str:
    """Apply YAML and return the created resource name (parsed from kubectl output).

    Returns empty string on dry-run.
    """
    if not apply:
        print("--- (dry-run) would apply:")
        print(manifest)
        print("---")
        return ""
    out = kubectl("apply", "-f", "-", stdin=manifest).stdout.strip()
    # Format: "<kind>.<group>/<name> <verb>" e.g. "volume.longhorn.io/r-foo created"
    if "/" in out:
        return out.split()[0].split("/", 1)[1]
    return ""


def restore_one(t: BackupTarget, args: argparse.Namespace, target_url: str) -> None:
    if not t.last_backup:
        log(f"SKIP {t.bv_name}: no backup found")
        return
    if not t.has_k8s_metadata:
        log(f"SKIP {t.bv_name}: no KubernetesStatus (restore manually via UI)")
        return

    # Filter helm_managed unless --helm was passed
    if t.restore_mode == "helm_managed" and not getattr(args, "helm", False):
        log(f"SKIP {t.bv_name}: helm_managed namespace '{t.pvc_namespace}' (pass --helm to restore)")
        return

    log(f"RESTORE [{t.restore_mode}] {t.bv_name} -> {t.pvc_namespace}/{t.pvc_name} "
        f"(backup={t.last_backup} size={t.size})")
    if t.restore_mode == "named_pv":
        log(f"  named PV mode: target volume = {t.named_volume_handle} "
            f"(Flux owns PV/PVC — script only restores the Longhorn volume)")

    # Idempotency: reuse an already-restored volume from a previous run.
    existing_restored = find_restored_volume(t)
    if existing_restored:
        log(f"  found existing restored volume: {existing_restored}")

    scaled_down: list[tuple[str, str, int]] = []  # (ns, workload, original_replicas)

    if kubectl_exists("get", "pvc", "-n", t.pvc_namespace, t.pvc_name):
        bound_pv = kubectl(
            "get", "pvc", "-n", t.pvc_namespace, t.pvc_name,
            "-o", "jsonpath={.spec.volumeName}", check=False,
        ).stdout.strip()
        current_vh = ""
        if bound_pv:
            current_vh = kubectl(
                "get", "pv", bound_pv, "-o", "jsonpath={.spec.csi.volumeHandle}",
                check=False,
            ).stdout.strip()

        if existing_restored and current_vh == existing_restored:
            log("  PVC already bound to restored volume — nothing to do")
            return

        if t.restore_mode == "named_pv":
            # For named_pv, the PVC is Flux-managed. If it exists but is bound
            # to a wrong/empty volume, we only need to restore the Longhorn volume
            # with the correct name — Flux will rebind the PVC on next reconcile.
            if not existing_restored:
                pass  # fall through to volume creation below
            else:
                log("  named_pv: Longhorn volume already exists; Flux will bind PVC")
                return
        else:
            if not args.replace:
                log("  SKIP: PVC exists and not bound to restored volume (pass --replace to overwrite)")
                return

            workloads = workloads_using_pvc(t.pvc_namespace, t.pvc_name)
            if workloads:
                if not args.scale_workloads:
                    warn(f"  PVC in use by: {', '.join(workloads)}")
                    warn("  refusing to delete; rerun with --scale-workloads or scale manually")
                    return
                for wl in workloads:
                    replicas_raw = kubectl(
                        "get", "-n", t.pvc_namespace, wl,
                        "-o", "jsonpath={.spec.replicas}", check=False,
                    ).stdout.strip()
                    original_replicas = int(replicas_raw) if replicas_raw.isdigit() else 1
                    scaled_down.append((t.pvc_namespace, wl, original_replicas))
                    if args.apply:
                        kubectl(
                            "annotate", "-n", t.pvc_namespace, wl,
                            f"{SCALE_ANNOTATION}={original_replicas}", "--overwrite",
                        )
                    scale_workload(t.pvc_namespace, wl, 0, args.apply)
                    if args.apply:
                        kubectl(
                            "wait", "-n", t.pvc_namespace, wl,
                            "--for=jsonpath={.status.replicas}=0", "--timeout=120s",
                            check=False,
                        )

            log(f"  DELETE PVC {t.pvc_namespace}/{t.pvc_name} (and bound PV {bound_pv})")
            if args.apply:
                kubectl("delete", "pvc", "-n", t.pvc_namespace, t.pvc_name, "--wait=true")

    if not kubectl_exists("get", "ns", t.pvc_namespace):
        log(f"  CREATE namespace {t.pvc_namespace}")
        if args.apply:
            kubectl("create", "namespace", t.pvc_namespace)

    from_backup = f"{target_url}/?backup={t.last_backup}&volume={t.vol_name}"

    if existing_restored:
        actual_vol = existing_restored
        log(f"  reusing Longhorn volume {actual_vol}")
    else:
        log(f"  CREATE Volume {t.desired_volume_name} from {from_backup}"
            + (" (Longhorn may truncate the name)" if len(t.desired_volume_name) > LONGHORN_MAX_VOL_NAME else ""))
        actual_vol = apply_yaml(
            f"""apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: {t.desired_volume_name}
  namespace: {LONGHORN_NS}
spec:
  size: "{t.size}"
  numberOfReplicas: {NUMBER_OF_REPLICAS}
  fromBackup: "{from_backup}"
  frontend: blockdev
  accessMode: {t.access_mode}
  dataEngine: v1
  dataLocality: disabled
  staleReplicaTimeout: 30
  revisionCounterDisabled: true
  backupTargetName: default
""",
            args.apply,
        ) or t.desired_volume_name

        if args.apply and actual_vol != t.desired_volume_name:
            log(f"  Longhorn renamed volume to {actual_vol}")
            if t.restore_mode == "named_pv":
                warn(f"  named_pv: volume was renamed by Longhorn — PVC will NOT bind!")
                warn(f"  expected '{t.desired_volume_name}', got '{actual_vol}'")
                warn(f"  check that the name is ≤{LONGHORN_MAX_VOL_NAME} characters")

    wait_for_restore(actual_vol, args.apply)

    # named_pv: Flux owns PV and PVC — do not create them here.
    if t.restore_mode == "named_pv":
        log(f"  named_pv: Longhorn volume '{actual_vol}' restored. "
            f"Run 'flux resume kustomization --all' to let Flux bind the PVC.")
        return

    log(f"  CREATE PV {t.restored_pv} (volumeHandle={actual_vol})")
    apply_yaml(
        f"""apiVersion: v1
kind: PersistentVolume
metadata:
  name: {t.restored_pv}
spec:
  capacity:
    storage: "{t.size}"
  volumeMode: Filesystem
  accessModes:
    - {t.k8s_access_mode}
  persistentVolumeReclaimPolicy: Retain
  storageClassName: {t.storage_class}
  csi:
    driver: driver.longhorn.io
    fsType: {FS_TYPE}
    volumeAttributes:
      numberOfReplicas: "{NUMBER_OF_REPLICAS}"
      staleReplicaTimeout: "30"
    volumeHandle: {actual_vol}
""",
        args.apply,
    )

    log(f"  CREATE PVC {t.pvc_namespace}/{t.pvc_name} (volumeName={t.restored_pv})")
    apply_yaml(
        f"""apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {t.pvc_name}
  namespace: {t.pvc_namespace}
spec:
  accessModes:
    - {t.k8s_access_mode}
  storageClassName: {t.storage_class}
  resources:
    requests:
      storage: "{t.size}"
  volumeName: {t.restored_pv}
""",
        args.apply,
    )

    for ns, workload, replicas in scaled_down:
        scale_workload(ns, workload, replicas, args.apply)
        if args.apply:
            kubectl(
                "annotate", "-n", ns, workload, f"{SCALE_ANNOTATION}-", check=False,
            )


def recover_scaled_down_workloads(args: argparse.Namespace) -> None:
    """Scale back up any workloads left at 0 replicas with the pre-restore annotation.

    Handles cancellation recovery: if a previous run scaled a workload down but
    crashed/was killed before scaling it back up, the annotation persists. This
    sweep finds and restores them. Respects --namespace filter.
    """
    log("recovery sweep: looking for workloads scaled down by a prior run...")
    for kind in ("deployment", "statefulset"):
        get_args = ["get", kind, "-o", "json"]
        if args.namespace:
            get_args += ["-n", args.namespace]
        else:
            get_args += ["-A"]
        result = kubectl(*get_args, check=False)
        if result.returncode != 0:
            continue
        items = json.loads(result.stdout).get("items", [])
        for item in items:
            anno = (item.get("metadata", {}).get("annotations") or {}).get(SCALE_ANNOTATION)
            if not anno:
                continue
            ns = item["metadata"]["namespace"]
            name = item["metadata"]["name"]
            workload = f"{item['kind']}/{name}"
            try:
                replicas = int(anno)
            except ValueError:
                warn(f"  {ns}/{workload}: invalid annotation value '{anno}' — skipping")
                continue
            current = item.get("spec", {}).get("replicas")
            if current == replicas:
                # Already at target; just strip the stale annotation.
                if args.apply:
                    kubectl("annotate", "-n", ns, workload,
                            f"{SCALE_ANNOTATION}-", check=False)
                continue
            scale_workload(ns, workload, replicas, args.apply)
            if args.apply:
                kubectl("annotate", "-n", ns, workload,
                        f"{SCALE_ANNOTATION}-", check=False)


def cmd_restore(args: argparse.Namespace) -> int:
    if not args.apply:
        log("DRY RUN — pass --apply to make changes")

    targets = list_backup_volumes()
    kept, dropped = dedupe_latest(targets)
    if dropped:
        log(f"deduped {len(dropped)} older backup(s) superseded by newer ones")

    kept = apply_filters(kept, args)
    if not kept:
        log("no backup volumes matched filters")
        return 0

    target_url = backup_target_url()
    log(f"backup target: {target_url}")

    for t in sorted(kept, key=lambda x: (x.pvc_namespace, x.pvc_name, x.bv_name)):
        try:
            restore_one(t, args, target_url)
        except subprocess.CalledProcessError as e:
            warn(f"failed restoring {t.bv_name}: {e.stderr or e}")

    if args.scale_workloads:
        recover_scaled_down_workloads(args)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_plan = sub.add_parser("plan", help="show what would be restored")
    p_plan.add_argument("--volume", help="filter to this BackupVolume name")
    p_plan.add_argument("--namespace", help="filter to PVCs in this namespace")
    p_plan.set_defaults(func=cmd_plan)

    p_restore = sub.add_parser("restore", help="execute restore")
    grp = p_restore.add_mutually_exclusive_group(required=True)
    grp.add_argument("--all", action="store_true", help="restore every eligible backup volume")
    grp.add_argument("--volume", help="restore only this BackupVolume")
    grp.add_argument("--namespace", help="restore only PVCs in this namespace")
    p_restore.add_argument("--apply", action="store_true",
                           help="actually create/delete resources (default: dry-run)")
    p_restore.add_argument("--replace", action="store_true",
                           help="if target PVC exists, delete it first")
    p_restore.add_argument("--scale-workloads", action="store_true",
                           help="auto-scale workloads using affected PVCs (down then up)")
    p_restore.add_argument("--helm", action="store_true",
                           help="also restore helm-managed PVCs (crowdsec, traefik, monitoring); "
                                "requires Helm charts already installed so PVCs exist")
    p_restore.set_defaults(func=cmd_restore)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
