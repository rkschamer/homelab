# Talos: Installation & Cluster Maintenance

## Installation

Cluster creation is semi-automated — Terraform handles VM provisioning and Talos config generation, but a few bootstrapping steps still require manual intervention (Proxmox Terraform provider limitations).

### Step 1: `terraform apply`

Navigate to [`terraform/`](../terraform/) and run `terraform apply`.

Proxmox will create VMs with SecureBoot enabled and cloud-init network configuration applied automatically:

- Control plane boots via DHCP on vmbr0 → receives **192.168.123.20** via static DHCP lease
- Worker nodes get static IPs via cloud-init:
  - **Worker-1**: 10.10.20.21/24
  - **Worker-2**: 10.10.20.22/24

All VMs boot from the Talos ISO and are ready to receive cluster configuration.

`terraform apply` also generates Talos machine configs in `talos/gen/`.

### Step 2: Apply Talos Configuration

Apply the generated configs to each node:

```bash
talosctl apply-config \
  --insecure \
  --nodes <node-ip> \
  --file ./talos/gen/<node-name>.yaml
```

Wait 2–3 minutes for the control plane to install and reboot.

**After reboot, make sure Talos boots from disk, not the ISO:**
- Enter the UEFI prompt and set the disk as boot device
- Remove the Talos ISO from the *Hardware* tab in Proxmox (not yet supported by the Terraform provider, so this is manual for now)

Then retrieve the kubeconfig:

```bash
talosctl kubeconfig -n 192.168.123.20 > ~/.kube/config
export KUBECONFIG=$HOME/.kube/config
kubectl get nodes
```

### Step 3: Bootstrap etcd

Once the control plane has rebooted:

```bash
talosctl bootstrap -n 192.168.123.20
```

### Step 4: Bootstrap Cilium and Flux

The cluster won't reach `Ready` state until Cilium (the CNI) is installed. Run the bootstrap script to install both Cilium and Flux:

```bash
./talos/bootstrap/bootstrap.sh
```

Flux takes over from here and reconciles everything else from this repo.

### Backup the Sealed Secrets Private Key

Once the cluster is up, export and store the Sealed Secrets controller's private key somewhere safe (Vaultwarden). This key is **not** managed by git-crypt and cannot be recovered if lost.

```bash
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-master.key
```

Store `sealed-secrets-master.key` securely and **do not commit it**.

---

## Cluster Maintenance

### Priority Classes

The cluster defines two custom PriorityClasses in [`flux/infrastructure/config/priority-classes.yaml`](../flux/infrastructure/config/priority-classes.yaml) to control eviction order when a node goes down and the surviving node cannot fit all pods.

| Class | Value | `globalDefault` |
|---|---|---|
| `homelab-critical` | 1 000 000 | false |
| `homelab-default` | 0 | **true** |

Because `homelab-default` is the `globalDefault`, every pod without an explicit `priorityClassName` automatically gets value 0. Only the critical workloads need an explicit assignment.

Full priority hierarchy (highest → lowest):

| Class | Value | Used by |
|---|---|---|
| `system-node-critical` | 2 000 001 000 | Cilium |
| `system-cluster-critical` | 2 000 000 000 | Flux source / kustomize / helm controllers |
| `longhorn-critical` | 2 000 000 | Longhorn manager, driver, UI (created by the Longhorn chart) |
| `homelab-critical` | 1 000 000 | Traefik, MetalLB, Sealed Secrets, snapshot-controller, Authelia, Vaultwarden, Pi-hole |
| `homelab-default` | 0 | Everything else (CrowdSec, monitoring stack, SiYuan, DoneTick, OrcaSlicer, Snowflake Proxy) |

When a node is drained or crashes and the remaining node lacks memory for all pending pods, the scheduler evicts `homelab-default` pods first to free space for `homelab-critical` ones. Critical services come back up; best-effort pods stay pending until the second node recovers.

### General Principles

- Always take a Proxmox snapshot of all cluster VMs before starting any upgrade.
- Upgrade one node at a time to maintain availability.
- Cordon and drain before touching a node.
- Workers first, control plane last.

### Pre-Upgrade Checklist

- [ ] All nodes in `Ready` state
- [ ] No stuck or pending pods across the cluster
- [ ] Persistent volumes healthy (check Longhorn UI)
- [ ] Proxmox snapshots created for all cluster VMs

### Talos OS Upgrades

Only adjacent minor version upgrades are supported. To go from v1.11 to v1.13, upgrade to the latest v1.12 patch first, then to v1.13.

```bash
export TALOSCONFIG=$(pwd)/talos/gen/talosconfig

# Check current version
talosctl version
```

**Step 1: bump the version and regenerate configs**

Update `talos_version` in [`terraform/variables.tf`](../terraform/variables.tf), then:

```bash
cd terraform && terraform apply
```

This regenerates machine configs in `talos/gen/` and updates the installer image reference. The target image is now available as a Terraform output — no copy-pasting from YAML files needed:

```bash
terraform output installer_image
# factory.talos.dev/installer-secureboot/<schematic-id>:vX.X.X
```

**Step 2: upgrade nodes** (workers first, control plane last)

```bash
cd terraform

# For each worker node (talosctl handles cordon/drain/uncordon automatically):
talosctl upgrade --nodes <NODE_IP> --image $(terraform output -raw installer_image)

# Monitor reboot and rejoin (~2–3 min)
watch kubectl get nodes

# Upgrade control plane last
talosctl upgrade --nodes 192.168.123.20 --image $(terraform output -raw installer_image)
```

### Kubernetes Version Upgrades

Talos manages the Kubernetes version directly:

```bash
talosctl upgrade-k8s --to 1.x.y
```

### Post-Upgrade Verification

- [ ] All nodes back in `Ready` state
- [ ] All system pods running
- [ ] `cilium status` healthy
- [ ] Application workloads healthy

---

## Rollback

### From Proxmox Snapshot (fastest)

```bash
qm stop <VMID>
qm rollback <VMID> <SNAPSHOT_NAME>
qm start <VMID>
kubectl get nodes
```

### Revert Talos Machine Config

```bash
talosctl apply-config --nodes <NODE_IP> --file reverted-config.yaml
watch kubectl get nodes
```

---

## Troubleshooting

### Node Stuck in `NotReady`

```bash
kubectl describe node <NODE_NAME>
talosctl logs --nodes <NODE_IP> kubelet
talosctl health --nodes <NODE_IP>
```

### Upgrade Didn't Complete

```bash
talosctl logs --nodes <NODE_IP> --services=update
# Retry:
talosctl upgrade --nodes <NODE_IP> --image ghcr.io/siderolabs/installer:vX.X.X
```

### Cluster Unreachable After Upgrade

1. Verify all VMs are running in Proxmox
2. Confirm control plane IP is reachable (`192.168.123.20`)
3. Restore from snapshot if needed

---

## External References

- [Talos Upgrade Guide](https://www.talos.dev/latest/talos-guides/upgrade/)
- [Cilium Upgrade Guide](https://docs.cilium.io/en/latest/operations/upgrade/)
