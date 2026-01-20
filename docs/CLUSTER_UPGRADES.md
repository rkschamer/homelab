# Cluster Upgrades and Maintenance

This guide covers operational procedures for upgrading and maintaining your Talos Kubernetes cluster, including OS and Kubernetes updates.

## General Principles

- **Backup First:** Always take a Proxmox snapshot of all cluster VMs before starting any upgrade.
- **Rolling Updates:** Upgrade one node at a time to maintain service availability.
- **Cordon and Drain:** Always cordon a node and drain workloads before performing maintenance.
- **Monitor Closely:** Watch the upgrade progress and be ready to rollback if issues occur.
- **GitOps for Automation:** Use System Upgrade Controller and define `Plan` manifests in this repository for fully automated upgrades.

## Upgrade Types

### OS Upgrades (Talos)

Talos is an immutable Linux distribution, so OS updates are applied via the talosctl CLI and automatically coordinated by Talos.

#### Prerequisites

```bash
# Export talosconfig for cluster access
export TALOSCONFIG=$(pwd)/talos/gen/talosconfig

# Verify current version
talosctl version

# Check nodes before upgrade
kubectl get nodes -o wide
```

#### Procedure: One Node at a Time

**Step 1: Cordon and Drain Worker Nodes First**

For each worker node:

```bash
# Replace NODE_NAME with actual node name
kubectl cordon <NODE_NAME>
kubectl drain <NODE_NAME> --ignore-daemonsets --delete-emptydir-data

# Verify node is drained
kubectl get pods -A --field-selector spec.nodeName=<NODE_NAME>
```

**Step 2: Upgrade Talos on Worker Node**

```bash
# Upgrade Talos (uses Talos update system)
talosctl upgrade --nodes <NODE_IP> --image ghcr.io/siderolabs/installer:vX.X.X

# Monitor the upgrade progress
talosctl health --nodes <NODE_IP>

# Wait for node to reboot and rejoin the cluster (~2-3 minutes)
watch kubectl get nodes
```

**Step 3: Uncordon Worker Node**

```bash
kubectl uncordon <NODE_NAME>

# Verify node is ready and accepting pods
kubectl get node <NODE_NAME>
```

**Step 4: Upgrade Control Plane Node**

After all worker nodes are updated, upgrade the control plane node **last**:

```bash
# Upgrade control plane
talosctl upgrade --nodes <CONTROL_PLANE_IP> --image ghcr.io/siderolabs/installer:vX.X.X

# Monitor upgrade
talosctl health --nodes <CONTROL_PLANE_IP>

# Verify cluster is healthy
kubectl get nodes
```

#### Verification After Upgrade

```bash
# Verify all nodes are at new version
talosctl version

# Verify all nodes are ready
kubectl get nodes

# Check for any pending pods
kubectl get pods -A --field-selector=status.phase!=Running

# Verify system components are healthy
kubectl get pods -n kube-system
kubectl get pods -n cilium
```

### Kubernetes Version Upgrades

Kubernetes versions are typically handled by Talos automatically based on the machine config. However, you can manually manage the k3s/Kubernetes version if needed:

```bash
# Check current Kubernetes version
kubectl version --short

# Update machine config to use a new Kubernetes version
talosctl edit machineconfig
# Modify the spec.kubernetesVersion field to the desired version

# Apply the updated config
talosctl apply-config --nodes <NODE_IP> --file updated-config.yaml
```

### CNI (Cilium) Upgrades

Cilium is managed via Helm in this repository:

```bash
# Check current Cilium version
helm list -n cilium

# Update Cilium Helm repository
helm repo add cilium https://helm.cilium.io
helm repo update

# Perform rolling upgrade
helm upgrade cilium cilium/cilium \
  --namespace cilium \
  --reuse-values \
  --wait

# Verify upgrade
kubectl get pods -n cilium
cilium status

# Check network policies are working
kubectl get cnp -A
```

## Automated Upgrades with System Upgrade Controller

For production environments, use the **System Upgrade Controller** to automate rolling updates declaratively via GitOps.

### Prerequisites

Install the System Upgrade Controller (one-time setup):

```bash
# Install the controller
helm repo add rancher https://releases.rancher.com/server-charts/stable
helm repo update

helm install system-upgrade-controller rancher/system-upgrade-controller \
  --namespace system-upgrade \
  --create-namespace \
  --set global.systemDefaultRegistry=""
```

### Define an Upgrade Plan (GitOps)

Create a `Plan` manifest in your `flux/infrastructure/` directory:

```yaml
# flux/infrastructure/talos-upgrade-plan.yaml
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: talos-upgrade
  namespace: system-upgrade
spec:
  concurrency: 1  # Upgrade one node at a time
  cordon: true    # Cordon before upgrade
  drain:
    force: true
    skipWaitForDeleteTimeout: 30
    deleteEmptyDirData: true
  nodeSelector:
    matchLabels:
      upgrade: "true"  # Only upgrade nodes with this label
  prepare:
    image: ghcr.io/siderolabs/installer:vX.X.X
    args:
      - "--system-upgrade-prepare"
  upgrade:
    image: ghcr.io/siderolabs/installer:vX.X.X
    args:
      - "--system-upgrade"
```

Then commit to Git and Flux will apply it. The controller will:
1. Cordon nodes matching the selector
2. Drain workloads gracefully
3. Perform the upgrade
4. Reboot and rejoin
5. Uncordon node
6. Move to the next node

## Rollback Procedures

### Quick Rollback: Restore from Proxmox Snapshot

If an upgrade causes critical issues, the fastest rollback is to restore from a Proxmox snapshot:

```bash
# In Proxmox UI or CLI:
# 1. Stop the affected VM
qm stop <VMID>

# 2. Restore from pre-upgrade snapshot
qm rollback <VMID> <SNAPSHOT_NAME>

# 3. Start the VM
qm start <VMID>

# 4. Verify cluster health
kubectl get nodes
```

### Graceful Rollback: Revert Machine Config

If the issue is related to Talos machine config changes:

```bash
# View current config
talosctl machineconfig --nodes <NODE_IP> | less

# Edit and remove the problematic change
talosctl edit machineconfig --nodes <NODE_IP>

# Apply the reverted config
talosctl apply-config --nodes <NODE_IP> --file reverted-config.yaml

# Verify the node rejoins the cluster
watch kubectl get nodes
```

## Pre-Upgrade Checklist

Before any upgrade, verify:

- [ ] All cluster nodes are in `Ready` state
- [ ] No pending pods across the cluster
- [ ] All persistent volumes are mounted and healthy
- [ ] Monitoring and alerting are operational
- [ ] Recent backup of etcd exists (if managed separately)
- [ ] Proxmox snapshots created for all cluster VMs
- [ ] Change window approved and users notified
- [ ] Rollback plan is documented and tested

## Post-Upgrade Verification

After each node upgrade:

- [ ] Node is back in `Ready` state
- [ ] All system pods are running
- [ ] Network connectivity is restored
- [ ] Monitoring shows no errors
- [ ] Application workloads are healthy
- [ ] No unusual resource usage

## Troubleshooting Upgrades

### Node Stuck in `NotReady`

```bash
# Check node status
kubectl describe node <NODE_NAME>

# Check kubelet logs
talosctl logs --nodes <NODE_IP> kubelet

# Check Talos system status
talosctl status --nodes <NODE_IP>

# If necessary, hard-reset the node
talosctl reset --nodes <NODE_IP> --graceful=false
```

### Upgrade Failed to Complete

```bash
# Check upgrade status
talosctl upgrade --nodes <NODE_IP> --check

# Examine Talos logs
talosctl logs --nodes <NODE_IP> --services=update

# Retry the upgrade
talosctl upgrade --nodes <NODE_IP> --image ghcr.io/siderolabs/installer:vX.X.X
```

### Cluster Communication Lost

If the cluster becomes unreachable after an upgrade:

1. Verify all VMs are running in Proxmox
2. Check control plane node IP (should be 192.168.123.20)
3. Restore from snapshot if critical services are affected
4. Contact the Talos community for advanced troubleshooting

## Additional Resources

- [Talos Upgrade Guide](https://www.talos.dev/latest/talos-guides/upgrade/)
- [System Upgrade Controller Documentation](https://rancher.com/docs/rancher/latest/en/system-tools/system-upgrade-controller/)
- [Cilium Upgrade Guide](https://docs.cilium.io/en/latest/operations/upgrade/)
