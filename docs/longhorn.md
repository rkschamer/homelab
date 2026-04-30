# Longhorn

Longhorn is the distributed block storage backend for all PersistentVolumeClaims in the cluster. Backups are written to an S3-compatible target (Garage) on a scheduled basis.

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
