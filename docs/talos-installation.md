# Talos Installation

This guide walks through creating VMs on Proxmox and bootstrapping a Talos Kubernetes cluster with network-isolated worker nodes using the control plane as a bastion host for accessing workers.

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
  │     ├─ Worker-Trusted (10.10.20.x on vmbr1)
  │     ├─ Worker-DMZ (10.10.30.x on vmbr2)
  │     ├─ Worker-Untrusted (10.10.40.x on vmbr3)
  │     └─ Worker-Monitoring (10.10.50.x on vmbr4)

Bootstrap Flow:
1. Admin machine boots control plane (accessible on 192.168.123.20)
2. Workers boot from ISO → won't receive a DHCP address; initial IP addresses must be set manually (10.10.x.21)
3. talosctl reaches workers via bastion tunnel for apply-config commands
4. After bootstrap, workers use LinkConfig for inter-network routing
```

## Step 1: `terraform apply`

- Navigate to [`proxmox/terraform/`](../proxmox/terraform/) and run `terraform apply`.
- Proxmox will create VMs and boot from the Talos ISO
- **⚠️ Caution**: Remove the ISO from the VMs via the Proxmox UI after booting is complete
- There is a static DHCP lease for `talos-controlplane-1` that assigns 192.168.123.20
- **⚠️ Caution**: Worker nodes will not receive DHCP addresses automatically.
  - Navigate to the Talos Dashboard via the Proxmox UI's VM Console
  - Manually set the IP address and gateway so the Talos config can be applied:

   | Worker | IP Address | Gateway | CIDR |
   |--------|-----------|---------|------|
   | talos-worker-trusted-1 | 10.10.20.21 | 10.10.20.2 | /24 |
   | talos-worker-dmz-1 | 10.10.30.21 | 10.10.30.2 | /24 |
   | talos-worker-untrusted-1 | 10.10.40.21 | 10.10.40.2 | /24 |
   | talos-worker-monitoring-1 | 10.10.50.21 | 10.10.50.2 | /24 |


## Step 2: `talosctl apply-config`

- Navigate to `proxmox/talos/gen`, which contains the generated Talos configuration for each node
- Set the TALOSCONFIG environment variable: `export TALOSCONFIG=$(pwd)/talosconfig`
- Apply the configuration to `talos-controlplane-1`:

  ```bash
  talosctl apply-config \
    --insecure \
    --nodes 192.168.123.20 \
    --file ./talos/gen/talos-controlplane-1.yaml
  ```
  - Wait 2-3 minutes for the control plane to install and reboot.
- Apply the configuration to worker nodes:

  ```bash
  # Replace with actual IPs from the Proxmox console
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
- Verify cluster health: `talosctl health`
- Retrieve the kubeconfig:
  ```bash
  talosctl kubeconfig -n 192.168.123.20 > ~/.kube/config
  export KUBECONFIG=$HOME/.kube/config
  kubectl get nodes
  ```

## Step 3: Install Cilium and Bootstrap Flux

Once all nodes are `Ready`:

### Install Cilium CNI and Hubble

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

For detailed instructions, see [CILIUM_HUBBLE_SETUP.md](../docs/CILIUM_HUBBLE_SETUP.md).

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

## Step 4: Verify End-to-End Connectivity

Verify that worker nodes can reach backend services:

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

### Admin machine cannot reach worker networks

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

### talosctl cannot reach worker nodes

```bash
# Verify admin machine has routes
ip route show

# Test connectivity to worker IP
ping 10.10.30.21

- Verify if the worker received a DHCP address
# Check the Proxmox console for the worker VM
# Should display "Endpoint: 10.10.30.x"

# If no IP address is assigned, verify the Proxmox host DHCP configuration
# (Your DHCP server or Proxmox dnsmasq should be providing addresses)
```

### Nodes remain in NotReady state

```bash
# Verify the CNI (Cilium) is deployed
kubectl get pods -n cilium

# Check node conditions
kubectl describe node talos-worker-dmz-1

# Review kubelet logs
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
- [Proxmox Network Setup](../proxmox/host/README.md)
- [LinkConfig Documentation](https://docs.siderolabs.com/talos/v1.12/reference/configuration/network/linkconfig)
- [Cilium and Hubble Installation](../docs/CILIUM_HUBBLE_SETUP.md)
