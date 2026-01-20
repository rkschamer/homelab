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

- Navigate to [`terraform/`](../terraform/) and run `terraform apply`.
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

## Step 3: Bootstrap the Cluster to enable GitOps

Normally the setup is designed to follow GitOps prinicple. However a few things need to be installed manually to get this to work.
All these commands are scripted in [../talos/bootstrap/bootstrap.sh](../talos/bootstrap/bootstrap.sh) and here only kept for explanation.

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
