# Bootstrap Guide: Network-Isolated Talos Cluster

This guide walks through bootstrapping a Talos Kubernetes cluster with network-isolated worker nodes using the control plane as a bastion host for accessing workers during bootstrap.

## Architecture Overview

```
Home LAN (192.168.123.0/24)
  ├─ Admin Machine (192.168.123.x)
  │  └─ Direct connection to Control Plane (192.168.123.20)
  │     └─ Control Plane acts as SSH bastion to reach workers
  │
  ├─ Proxmox Host (192.168.123.8)
  │  └─ Kubernetes Cluster
  │     ├─ Control Plane (192.168.123.20 on vmbr0)
  │     │  └─ SSH access for bastion tunneling
  │     ├─ Worker-Trusted (10.10.20.x on vmbr1)
  │     ├─ Worker-DMZ (10.10.30.x on vmbr2)
  │     ├─ Worker-Untrusted (10.10.40.x on vmbr3)
  │     └─ Worker-Monitoring (10.10.50.x on vmbr4)

Bootstrap Flow:
1. Admin machine boots control plane (accessible on 192.168.123.20)
2. Workers boot on ISO → get DHCP from workload network (10.10.x.21)
3. Admin reaches workers via SSH tunnel through control plane bastion
4. talosctl reaches workers via bastion tunnel for apply-config commands
5. After bootstrap, workers use LinkConfig for inter-network routing
```

## Prerequisites

Before starting:

1. Proxmox host is fully configured with network bridges (vmbr0-4)
   - Check: [proxmox/host/NETWORK_SETUP.md](../proxmox/host/NETWORK_SETUP.md)
   - Run: `sysctl net.ipv4.ip_forward` should return `1`

2. Admin machine can reach Proxmox host on 192.168.123.8
   - Test: `ping 192.168.123.8`

3. Terraform has created all VMs
   - Check: `proxmox/terraform/terraform.tfstate` exists
   - Verify in Proxmox UI: All control plane and worker VMs exist

4. Tools installed on admin machine:
   - `talosctl` - for Talos management
   - `kubectl` - for Kubernetes management
   - `helm` - for package deployment
   - `ssh` - for bastion tunneling (standard on Linux/macOS)

5. SSH access capability
   - Admin machine can SSH to control plane once it's booted
   - Control plane can access workers on their workload networks

## Step 1: No Admin Machine Routes Needed

Unlike the static routes approach, the bastion tunnel method requires **NO manual routing configuration** on your admin machine. The control plane will automatically route traffic to workers via its internal connections.

The control plane:
- Is directly accessible on 192.168.123.20 from your home LAN
- Has network connectivity to all worker nodes (they're on the same Proxmox host)
- Acts as an SSH bastion for reaching workers on 10.10.x.x networks

This is cleaner than static routes because:
- ✓ No manual routing configuration required
- ✓ Works seamlessly on all admin machine OSes
- ✓ Control plane routing is deterministic (internal to Proxmox host)
- ✓ No persistent route configuration needed

## Step 2: Boot VMs and Set Worker Static IPs via Console

### Boot Control Plane

```bash
qm start 200  # talos-controlplane-1
```

Monitor the Proxmox console and wait for:
```
Endpoint: 192.168.123.20
```

Verify SSH access works (confirms bastion connectivity):
```bash
ssh talosctl@192.168.123.20
exit
```

### Boot Workers and Configure Static IPs

Since workload networks (vmbr1-4) have no DHCP servers, manually set static IPs via Proxmox console:

1. **Start each worker VM:**
   ```bash
   qm start 220  # talos-worker-trusted-1
   qm start 221  # talos-worker-dmz-1
   qm start 222  # talos-worker-untrusted-1
   qm start 223  # talos-worker-monitoring-1
   ```

2. **For each worker, configure static IP via Proxmox console:**
   - Open Proxmox web UI → Select worker VM → Console tab
   - Watch the Talos boot sequence
   - When you see the boot menu, press **'c'** for console/dashboard access
   - Navigate to network configuration
   - Set static IP using these values:

   | Worker | IP Address | Gateway | CIDR |
   |--------|-----------|---------|------|
   | talos-worker-trusted-1 | 10.10.20.21 | 10.10.20.1 | /24 |
   | talos-worker-dmz-1 | 10.10.30.21 | 10.10.30.1 | /24 |
   | talos-worker-untrusted-1 | 10.10.40.21 | 10.10.40.1 | /24 |
   | talos-worker-monitoring-1 | 10.10.50.21 | 10.10.50.1 | /24 |

   - Boot/continue after configuration
   - Verify in console shows: `Endpoint: 10.10.x.21`

3. **Document the IPs** - you'll use these in the next step when applying configs

## Step 3: Apply Talos Configuration

Set environment variables:

```bash
cd /path/to/homelab/proxmox/terraform

export TALOSCONFIG=$(pwd)/talos/gen/talosconfig
export KUBECONFIG=$HOME/.kube/config
```

Configure talosctl endpoints:

```bash
# Set control plane endpoint
talosctl config endpoint 192.168.123.20
talosctl config node 192.168.123.20
```

**Apply control plane configuration:**

```bash
talosctl apply-config \
  --insecure \
  --nodes 192.168.123.20 \
  --file ./talos/gen/talos-controlplane-1.yaml
```

Wait 2-3 minutes for control plane to install and reboot.

**Apply worker configurations:**

Use the DHCP IPs you noted from the console earlier:

```bash
# Replace with actual IPs from Proxmox console
talosctl apply-config \
  --insecure \
  --nodes 10.10.20.21 \
  --file ./talos/gen/talos-worker-trusted-1.yaml

talosctl apply-config \
  --insecure \
  --nodes 10.10.30.21 \
  --file ./talos/gen/talos-worker-dmz-1.yaml

talosctl apply-config \
  --insecure \
  --nodes 10.10.40.21 \
  --file ./talos/gen/talos-worker-untrusted-1.yaml

talosctl apply-config \
  --insecure \
  --nodes 10.10.50.21 \
  --file ./talos/gen/talos-worker-monitoring-1.yaml
```

Each node will:
1. Install Talos to disk
2. Reboot automatically
3. Configure networking using LinkConfig manifests
4. Join the Kubernetes cluster

**Patience Required:** This takes 1-2 minutes per node. Monitor progress in Proxmox console for each VM.

## Step 4: Verify Cluster Readiness

**Wait for control plane to be ready:**

```bash
# Check health
talosctl health
# Output should show:
# [talos-controlplane-1] Cluster is healthy
```

**Get kubeconfig:**

```bash
talosctl kubeconfig -n 192.168.123.20 > ~/.kube/config
export KUBECONFIG=$HOME/.kube/config
```

**Check nodes:**

```bash
kubectl get nodes

# Expected output (may take 3-5 minutes):
# NAME                     STATUS   ROLES           AGE    VERSION
# talos-controlplane-1     Ready    control-plane   5m     v1.29.x
# talos-worker-trusted-1   Ready    <none>          3m     v1.29.x
# talos-worker-dmz-1       Ready    <none>          3m     v1.29.x
# talos-worker-untrusted-1 Ready    <none>          3m     v1.29.x
# talos-worker-monitoring-1 Ready   <none>          3m     v1.29.x
```

**Troubleshooting node status:**

Nodes may show `NotReady` initially - this is normal while Cilium CNI is being deployed.

```bash
# Check if nodes are waiting for CNI
kubectl describe node talos-worker-dmz-1 | grep -i "not ready"

# Check CNI pod status (wait for Cilium deployment)
kubectl get pods -n kube-system

# If nodes are stuck, check talosctl logs
talosctl logs -k kubelet -n 10.10.30.21
```

## Step 5: Bootstrap Kubernetes Components

Once all nodes are `Ready`:

### Install Cilium CNI + Hubble

```bash
helm repo add cilium https://helm.cilium.io
helm repo update

helm install cilium cilium/cilium \
  --namespace cilium \
  --create-namespace \
  --set kubeProxyReplacement=true \
  --set ebpf.enabled=true \
  --set hubble.enabled=true \
  --set hubble.ui.enabled=true \
  --wait

# Verify
kubectl get pods -n cilium
```

For detailed instructions, see [docs/CILIUM_HUBBLE_SETUP.md](../docs/CILIUM_HUBBLE_SETUP.md)

### Install MetalLB

```bash
helm repo add metallb https://metallb.universe.tf
helm repo update

helm install metallb metallb/metallb \
  --namespace metallb-system \
  --create-namespace \
  --wait
```

Create MetalLB configuration:

```bash
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
  - 192.168.123.21-192.168.123.29

---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default
  nodeSelectors:
  - matchLabels:
      kubernetes.io/hostname: talos-controlplane-1
EOF
```

### Install Sealed Secrets

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --wait
```

## Step 6: Verify End-to-End Connectivity

Test that workers can reach backend services:

```bash
# Deploy a test pod on DMZ worker
kubectl run test-pod --image=alpine --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"talos-worker-dmz-1"}}}' -it -- /bin/sh

# Inside the pod:
ping 192.168.123.20    # Should reach control plane
ping 10.10.20.1        # Should reach other networks
nslookup kubernetes.default.svc.cluster.local  # Should resolve
exit

# Clean up
kubectl delete pod test-pod
```

## Troubleshooting

### Admin machine can't reach worker networks

```bash
# Check routes on admin machine
ip route show | grep 10.10

# Check Proxmox host has IP forwarding enabled
ssh root@192.168.123.8 sysctl net.ipv4.ip_forward
# Should return: net.ipv4.ip_forward = 1

# Check Proxmox bridge gateways
ssh root@192.168.123.8 ip addr show | grep 10.10
# Should show: inet 10.10.20.1/24 dev vmbr1, etc.
```

### talosctl can't reach worker nodes

```bash
# Verify admin machine has routes
ip route show

# Test connectivity to worker IP
ping 10.10.30.21

# Check if worker got DHCP
# Look at Proxmox console for the worker VM
# Should show "Endpoint: 10.10.30.x"

# If no IP, check Proxmox host DHCP
# (Your DHCP server or Proxmox dnsmasq should be providing IPs)
```

### Nodes stay in NotReady state

```bash
# Check CNI (Cilium) is deployed
kubectl get pods -n cilium

# Check node conditions
kubectl describe node talos-worker-dmz-1

# Check kubelet logs
talosctl logs -k kubelet -n 10.10.30.21
```

## Architecture Diagram After Bootstrap

```
┌─────────────────────────────────────────────────────────────────┐
│ Admin Machine (192.168.123.x)                                   │
│ Routes: 10.10.x.0/24 → 192.168.123.8                            │
└──────────────────────┬──────────────────────────────────────────┘
                       │ SSH / talosctl / kubectl
                       ↓
┌─────────────────────────────────────────────────────────────────┐
│ Proxmox Host (192.168.123.8)                                    │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ Kubernetes Cluster (Talos)                                  │ │
│ │                                                             │ │
│ │ vmbr0 (Management 192.168.123.0/24):                       │ │
│ │ └─ talos-controlplane-1 (192.168.123.20)                   │ │
│ │    ├─ Cilium + Hubble                                      │ │
│ │    ├─ MetalLB Speaker (advertises 192.168.123.21-29)       │ │
│ │    └─ Sealed Secrets                                       │ │
│ │                                                             │ │
│ │ vmbr1 (Trusted 10.10.20.0/24):                             │ │
│ │ └─ talos-worker-trusted-1 (10.10.20.21)                    │ │
│ │                                                             │ │
│ │ vmbr2 (DMZ 10.10.30.0/24):                                 │ │
│ │ └─ talos-worker-dmz-1 (10.10.30.21)                        │ │
│ │    └─ [Traefik will run here]                              │ │
│ │                                                             │ │
│ │ vmbr3 (Untrusted 10.10.40.0/24):                           │ │
│ │ └─ talos-worker-untrusted-1 (10.10.40.21)                  │ │
│ │                                                             │ │
│ │ vmbr4 (Monitoring 10.10.50.0/24):                          │ │
│ │ └─ talos-worker-monitoring-1 (10.10.50.21)                 │ │
│ │                                                             │ │
│ │ Cilium CNI: Replaces kube-proxy, handles pod networking    │ │
│ └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## Next Steps

After bootstrap is complete:

1. **[Install Cilium & Hubble](../docs/CILIUM_HUBBLE_SETUP.md)** - CNI and observability
2. **Install Flux CD** - GitOps for application deployment
3. **Deploy Traefik** - Ingress controller for external traffic
4. **Deploy applications** - Use Flux to manage all deployments

## References

- [Talos Documentation](https://www.talos.dev/)
- [Proxmox Network Setup](../proxmox/host/NETWORK_SETUP.md)
- [LinkConfig Documentation](https://docs.siderolabs.com/talos/v1.12/reference/configuration/network/linkconfig)
- [Cilium Installation](../docs/CILIUM_HUBBLE_SETUP.md)
