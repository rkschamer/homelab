# Talos Installation

This guide walks through creating VMs on Proxmox and bootstrapping a Talos Kubernetes cluster on a single workload network, with pod-level network isolation enforced via Cilium Network Policies.

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
  │     ├─ Worker-1 (10.10.20.21 on vmbr1)
  │     └─ Worker-2 (10.10.20.22 on vmbr1)

Bootstrap Flow:
1. Admin machine boots control plane (accessible on 192.168.123.20)
2. Workers boot from ISO → won't receive a DHCP address; initial IP addresses must be set manually (10.10.20.21, 10.10.20.22)
3. talosctl reaches workers via bastion tunnel for apply-config commands
4. After bootstrap, workers use LinkConfig for inter-network routing
```

## Step 1: `terraform apply`

- Navigate to [`terraform/`](../terraform/) and run `terraform apply`.
- Proxmox will create VMs and boot from the Talos ISO
- **⚠️ Caution**: Remove the ISO from the VMs via the Proxmox UI after booting is complete
- There is a static DHCP lease for `talos-controlplane-1` that assigns 192.168.123.20
- **⚠️ Caution**: Worker nodes will not receive DHCP addresses automatically.
  - Navigate to the Talos Dashboard via the Proxmox UI's VM Console
  - Manually set the IP address and gateway so the Talos config can be applied:

   | Worker | IP Address | Gateway | CIDR |
   |--------|-----------|---------|------|
   | talos-worker-1 | 10.10.20.21 | 10.10.20.2 | /24 |
   | talos-worker-2 | 10.10.20.22 | 10.10.20.2 | /24 |


## Step 2: `talosctl apply-config`

- Navigate to `talos/gen`, which contains the generated Talos configuration for each node
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
  # Worker 1
  talosctl apply-config \
    --insecure \
    --nodes 10.10.20.21 \
    --file ./talos/gen/talos-worker-1.yaml

  # Worker 2
  talosctl apply-config \
    --insecure \
    --nodes 10.10.20.22 \
    --file ./talos/gen/talos-worker-2.yaml
  ```
- Verify cluster health: `talosctl health`
- Retrieve the kubeconfig:
  ```bash
  talosctl kubeconfig -n 192.168.123.20 > ~/.kube/config
  export KUBECONFIG=$HOME/.kube/config
  kubectl get nodes
  ```

## Step 3: Bootstrap the Cluster to enable GitOps

Normally the setup is designed to follow GitOps prinicple. However a few things need to be installed manually to get this to work.
All these commands are scripted in [../talos/bootstrap/bootstrap.sh](../talos/bootstrap/bootstrap.sh) and here only kept for explanation.

# Workload Placement via Namespace Labels

**Network zones are now enforced at the pod level, not at the node level.** All workers run on the same network (`10.10.20.0/24`), and Cilium Network Policies enforce isolation based on namespace labels.

## Workload Placement Strategy

Apply the `network-zone` label to namespaces to define security zones:

```bash
# Trusted zone (internal services with home LAN access)
kubectl create namespace homeassistant
kubectl label namespace homeassistant network-zone=trusted

# DMZ zone (public-facing services like Traefik)
kubectl create namespace traefik
kubectl label namespace traefik network-zone=dmz

# Untrusted zone (experimental workloads, internet-only)
kubectl create namespace experimental
kubectl label namespace experimental network-zone=untrusted

# Monitoring zone (observability infrastructure)
kubectl create namespace monitoring
kubectl label namespace monitoring network-zone=monitoring
```

## Network Zone Isolation

| Zone | Namespace Label | Purpose | Pod Connectivity |
|------|-----------------|---------|----------------------|
| **Trusted** | `network-zone: trusted` | Internal services (Home Assistant, NAS, file servers) with home LAN access | Can reach: Home LAN, Management, Internet |
| **DMZ** | `network-zone: dmz` | Public-facing services (Traefik Ingress). Must be isolated from home LAN | Can reach: Internet, explicit Trusted pods; Blocked: Home LAN |
| **Untrusted** | `network-zone: untrusted` | Experimental workloads, development, testing, sandboxing | Can reach: Internet only; Blocked: Home LAN, Trusted, DMZ, Monitoring |
| **Monitoring** | `network-zone: monitoring` | Observability infrastructure (Prometheus, Grafana, Hubble). Pull-based metrics collection | Can reach: All zones (pull-only); Others cannot push to Monitoring |

## Why No NodeSelector?

**Before:** Each worker node was dedicated to a single network zone. Deployments used `nodeSelector` to pin pods to specific nodes.

**Now:** All workers share the same network. Pod placement is determined by **Cilium Network Policies**, not node affinity. Pods can run on any worker and Cilium still enforces zone boundaries via namespace labels.

## Benefits of Pod-Level Isolation

1. **Flexible Scheduling:** Pods can run on any worker; Cilium enforces isolation
2. **Node Scaling:** Easy to add more workers without network reconfiguration
3. **High Availability:** Can cordon/drain workers during upgrades; pods reschedule freely
4. **Industry Standard:** Namespace + NetworkPolicy is the common Kubernetes pattern
5. **Reduced Overhead:** 2 VMs instead of 4; half the memory, CPU, and disk usage on Proxmox

## Important: DMZ Pod Isolation

The DMZ zone (Traefik, public APIs) must be isolated from the Home LAN at the pod level. When creating Cilium policies, ensure:

```yaml
# Example: Block DMZ pods from accessing Home LAN
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: deny-dmz-to-home-lan
spec:
  endpointSelector:
    matchLabels:
      io.cilium.k8s.namespace.labels.network-zone: dmz
  egressDeny:
    - toCIDR:
        - 192.168.123.0/24  # Home LAN
```

This ensures public-facing services cannot accidentally access home machines even though they share the same physical network.



### Install Cilium CNI and Hubble

```bash
cilium install \
  --datapath-mode ebpf \
  --enable-hubble \
  --enable-host-firewall \
  --enable-hubble-ui

cilium status --wait
```

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

#### Backup the Sealed Secrets Private Key

After Sealed Secrets is deployed, the controller generates a private key that is used to encrypt all secrets. **This key must be backed up and stored securely** in case you need to recreate the cluster. Without it, you won't be able to decrypt existing sealed secrets.

**Export the private key:**

```bash
# Export the private key to a file
kubectl get secret -n kube-system sealed-secrets-keys -o jsonpath='{.data.tls\.key}' | base64 -d > sealed-secrets-private.key

# Also export the certificate for reference
kubectl get secret -n kube-system sealed-secrets-keys -o jsonpath='{.data.tls\.crt}' | base64 -d > sealed-secrets-cert.crt

# Alternatively, export the entire secret as YAML for storage
kubectl get secret -n kube-system sealed-secrets-keys -o yaml > sealed-secrets-secret-backup.yaml
```

**Store these files securely** in your password manager (e.g., Vaultwarden) or offline backup storage. Do NOT commit these files to the Git repository.

#### Restore the Sealed Secrets Private Key

When setting up a new cluster, restore the backed-up private key **before deploying Sealed Secrets** so that existing encrypted secrets can be decrypted.

**Option 1: Restore from backed-up files (before bootstrap)**

```bash
# Create the secret from the exported files
kubectl create secret tls sealed-secrets-keys \
  --cert=sealed-secrets-cert.crt \
  --key=sealed-secrets-private.key \
  -n kube-system
```

**Option 2: Apply the backed-up YAML**

```bash
kubectl apply -f sealed-secrets-secret-backup.yaml
```

**Important**: The secret must exist in the `kube-system` namespace with the name `sealed-secrets-keys` before Sealed Secrets HelmRelease is deployed. Once the secret exists, Flux will deploy Sealed Secrets and it will use the existing key instead of generating a new one.

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
