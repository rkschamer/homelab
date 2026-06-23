# Longhorn

Longhorn is the distributed block storage backend for all PersistentVolumeClaims in the cluster. Backups are written to an S3-compatible target (Garage) on a scheduled basis.

## Named PV convention

All stateful services use **named PersistentVolumes** rather than relying on Longhorn's auto-generated UUID volume names. This makes the cluster fully reproducible from Git without manual intervention after a restore.

### Naming scheme

| Object | Name pattern | Example |
|---|---|---|
| Longhorn volume | `pv-<service>-<purpose>` | `pv-vaultwarden-data` |
| Kubernetes PV | same as Longhorn volume | `pv-vaultwarden-data` |
| Kubernetes PVC | descriptive, matches manifest | `vaultwarden-data` |

### PV manifest template

Every stateful service has a PV manifest committed alongside its PVC. The `volumeHandle` must match the Longhorn volume name exactly. The `claimRef` pre-binds the PV to the correct PVC so Longhorn auto-provisioning is bypassed:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-<service>-<purpose>
  annotations:
    pv.kubernetes.io/provisioned-by: driver.longhorn.io
spec:
  capacity:
    storage: <size>
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    volumeHandle: pv-<service>-<purpose>
    fsType: ext4
    volumeAttributes:
      migratable: "true"
      numberOfReplicas: "2"
      staleReplicaTimeout: "2880"
  claimRef:
    namespace: <namespace>
    name: <pvc-name>
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <pvc-name>
  namespace: <namespace>
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  volumeName: pv-<service>-<purpose>
  resources:
    requests:
      storage: <size>
```

### On first deploy (no existing data)

Nothing to do. Flux applies the PV and PVC manifests; when the pod starts, the CSI driver calls Longhorn which creates the volume automatically. The named PV convention does not require pre-creating volumes on a first install.

### On a restore (from Longhorn backup)

**Do this before Flux reconciles workload kustomizations** — PVCs will remain `Pending` until the Longhorn volume exists.

1. In **Longhorn UI → Backup**, restore each volume and set the **Name** to the `pv-<service>-<purpose>` name from Git
2. Flux will create the PV and PVC objects automatically — they bind immediately since `volumeHandle` and `volumeName` match
3. No manual `kubectl apply` needed

### On a fresh install (no backup)

Nothing to do — Longhorn creates the volume automatically when the pod first mounts it. The CSI driver calls Longhorn with the named `volumeHandle` and Longhorn provisions a new empty volume with that name on demand.

### Why not use Longhorn auto-provisioning?

When Longhorn auto-provisions a PVC via StorageClass it assigns a UUID volume name (e.g. `pvc-6e68c265-...`). On a cluster rebuild the new UUID won't match the backup volume name, requiring manual PV/PVC creation and `volumeName` patching. Named volumes eliminate this entirely.

## Backup target

Backups are stored in `s3://longhorn-bucket@garage`. The backup schedule and retention are configured in the Longhorn UI under **Setting → Backup**.

## Expanding a PVC

Longhorn supports online volume expansion (no pod restart required).

```bash
kubectl patch pvc <pvc-name> -n <namespace> \
  -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
```

For **StatefulSet** workloads the `volumeClaimTemplate` in the StatefulSet spec is immutable. After expanding the PVC directly, update the value in the HelmRelease to match reality, then delete and recreate the StatefulSet so Helm can render the new template size:

```bash
kubectl delete statefulset <name> -n <namespace> --cascade=orphan
flux reconcile helmrelease <name> -n <namespace> --reset
```

`--cascade=orphan` keeps the pod running while the StatefulSet object is recreated.

## Helm-managed PVCs

Some services have PVCs created and named by their Helm chart rather than by explicit manifests in Git. These cannot use the named PV convention because the chart controls the PVC name and does not expose an `existingClaim` value.

| Service | PVC name(s) | Data criticality |
|---|---|---|
| CrowdSec | `crowdsec-db-pvc`, `crowdsec-config-pvc` | Low — community blocklist re-syncs from CAPI on startup |
| Traefik | `traefik` | Medium — contains `acme.json` (TLS certs); ACME re-issues automatically |
| Prometheus | `prometheus-prometheus-release-kube-pr-db-...` | Low — metrics history only |
| Alertmanager | `alertmanager-prometheus-release-kube-pr-db-...` | Low — alert state only |
| Grafana | `prometheus-release-grafana` | Low — dashboards are defined in Git |
| Loki | `storage-loki-0` | Low — log history only |

### Restore procedure for Helm-managed PVCs

These PVCs are provisioned by Longhorn auto-provisioning (UUID volume names). On a fresh cluster install, Helm creates new empty PVCs automatically — **no restore needed for low-criticality services**.

For services where you want to restore data (e.g. Traefik's `acme.json`):

1. Let Helm install the chart first so the PVC exists with its chart-assigned name
2. Scale the workload to zero:
   ```bash
   kubectl scale deploy <name> -n <namespace> --replicas=0
   ```
3. Note the PVC's auto-assigned PV name:
   ```bash
   kubectl get pvc -n <namespace> <pvc-name> -o jsonpath='{.spec.volumeName}'
   ```
4. In **Longhorn UI → Backup**, restore the backup volume — set the restore name to the PV name from step 3
5. In Longhorn UI, delete the empty auto-provisioned volume (the one created in step 1)
6. The PVC will re-bind to the restored volume automatically
7. Scale the workload back up

> For Traefik specifically: if `acme.json` is lost, Traefik will re-request certificates from Let's Encrypt on next startup. This works fine but may hit rate limits if done repeatedly. Let's Encrypt issues a new cert within seconds on first request.

## Recovering a volume from backup

Use this procedure when a Longhorn volume is faulted, deleted, or needs to be restored to a prior snapshot.

### 1. Stop the workload

Scale the workload to zero so Longhorn can fully detach the volume. For a StatefulSet managed by the Prometheus Operator, also pause the custom resource to prevent the operator from fighting the scale-down:

```bash
# For Prometheus Operator-managed resources
kubectl patch prometheus <name> -n <namespace> --type=merge -p '{"spec":{"paused":true}}'

kubectl scale statefulset <name> -n <namespace> --replicas=0
```

Wait for the pod to terminate before continuing.

### 2. Clear stuck PVC/PV (if Terminating)

If the PVC and PV are stuck in `Terminating`, remove their finalizers:

```bash
kubectl patch pvc <pvc-name> -n <namespace> \
  -p '{"metadata":{"finalizers":null}}' --type=merge

kubectl patch pv <pv-name> \
  -p '{"metadata":{"finalizers":null}}' --type=merge
```

### 3. Identify the backup

```bash
kubectl get backupvolume -n longhorn-system | grep <pvc-name>
kubectl get backup <backup-name> -n longhorn-system \
  -o jsonpath='{.status.url}'
```

Note the backup URL — it looks like:
`s3://longhorn-bucket@garage/?backup=backup-<id>&volume=<volume-name>`

### 4. Restore via Longhorn API

If the Longhorn volume no longer exists, restore it from backup using the Longhorn manager API. The volume name must match the original PV name so the PVC binding works.

```bash
kubectl run -n longhorn-system curl-restore --image=curlimages/curl:8.7.1 \
  --restart=Never --rm -i -- \
  curl -s -X POST \
    "http://longhorn-backend.longhorn-system.svc.cluster.local:9500/v1/volumes" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "<pv-name>",
      "size": "<size-in-bytes>",
      "numberOfReplicas": 2,
      "fromBackup": "<backup-url>"
    }'
```

If the volume already exists but is faulted, use the salvage action instead (the volume must be in `detached` state first):

```bash
kubectl run -n longhorn-system curl-salvage --image=curlimages/curl:8.7.1 \
  --restart=Never --rm -i -- \
  curl -s -X POST \
    "http://longhorn-backend.longhorn-system.svc.cluster.local:9500/v1/volumes/<volume-name>?action=salvage" \
    -H "Content-Type: application/json" \
    -d '{"names": ["<faulted-replica-name>"]}'
```

### 5. Create PV and PVC

Pre-create the PV and PVC **before** scaling the workload back up. If the StatefulSet starts without an existing PVC, the controller will dynamically provision a new empty volume and ignore the restored one.

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: <pv-name>
  annotations:
    pv.kubernetes.io/provisioned-by: driver.longhorn.io
spec:
  capacity:
    storage: <size>
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    volumeHandle: <pv-name>
    fsType: ext4
    volumeAttributes:
      migratable: "true"
      numberOfReplicas: "2"
      staleReplicaTimeout: "2880"
  claimRef:
    namespace: <namespace>
    name: <pvc-name>
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <pvc-name>
  namespace: <namespace>
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: <size>
  storageClassName: longhorn
  volumeName: <pv-name>
EOF
```

The `claimRef` on the PV and `volumeName` on the PVC pre-bind the two objects to each other. The PVC should immediately show `Bound`.

### 6. Scale the workload back up

```bash
kubectl scale statefulset <name> -n <namespace> --replicas=1

# If paused via Prometheus Operator
kubectl patch prometheus <name> -n <namespace> --type=merge -p '{"spec":{"paused":false}}'
```

Longhorn will attach the restored volume to the node where the pod is scheduled. Initial attach can take 1–2 minutes while replicas start.

## Troubleshooting

**`volume is not ready for workloads`** — The volume's robustness is `faulted`. Stop the workload to let the volume fully detach, then use the salvage API call above.

**Volume stuck cycling between `attaching` and `detaching`** — The pod keeps getting recreated before the volume can fully attach. Scale the StatefulSet to 0 (and pause the operator if applicable) to break the cycle, then wait for the volume to reach `detached` before salvaging.

**`entry too far behind` errors in Fluent Bit after Loki recovery** — Fluent Bit is flushing buffered logs from while Loki was down. Loki rejects entries older than its configured `reject_old_samples_max_age`. This is self-resolving; Fluent Bit drops the old entries and catches up to current time automatically.
