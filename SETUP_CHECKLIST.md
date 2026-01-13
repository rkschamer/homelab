# Kubernetes Homelab Setup Checklist

This document provides a comprehensive checklist and quick reference for the entire homelab setup, ensuring all components are properly configured before bootstrapping the cluster.

## Prerequisites Checklist

### Proxmox VE Configuration ✓

- [ ] **Proxmox Host Networking**
  - [ ] Five virtual bridges created (vmbr0-4)
  - [ ] Bridge gateways configured:
    - `vmbr0`: 192.168.123.8
    - `vmbr1`: 10.10.20.1
    - `vmbr2`: 10.10.30.1
    - `vmbr3`: 10.10.40.1
    - `vmbr4`: 10.10.50.1
  - [ ] IP forwarding enabled: `sysctl net.ipv4.ip_forward = 1`
  - [ ] See [proxmox/host/NETWORK_SETUP.md](proxmox/host/NETWORK_SETUP.md) for detailed setup

- [ ] **API Token**
  - [ ] Created in Proxmox web UI
  - [ ] Token credentials stored in `terraform.tfvars`
  - [ ] Test connection: `curl -X GET https://pve.kschamer.info/api2/json/version -H "Authorization: PVEAPIToken=..."`

### Local Admin Machine ✓

- [ ] **Bastion Access to Control Plane**
  - [ ] Admin machine can reach Proxmox host: `ping 192.168.123.8`
  - [ ] Admin machine can reach control plane: `ping 192.168.123.20`
  - [ ] SSH key-based auth available (optional but recommended)

- [ ] **Tools Installed**
  - [ ] `talosctl`: `talosctl version`
  - [ ] `kubectl`: `kubectl version --client`
  - [ ] `helm`: `helm version`
  - [ ] `cilium-cli` (optional): `cilium version`
  - [ ] `ssh`: Available on Linux/macOS, PuTTY or similar on Windows

### Git Repository ✓

- [ ] **Repository Structure**
  - [ ] `README.md` - Main documentation
  - [ ] `LICENSE` - Project license
  - [ ] `proxmox/terraform/` - Infrastructure as Code
  - [ ] `proxmox/host/` - Proxmox host configuration
  - [ ] `docs/` - Additional guides and documentation
  - [ ] `secrets/` - (Created after bootstrap for sealed secrets)

## Terraform Configuration Checklist

### Configuration Files ✓

- [ ] **terraform.tfvars**
  - [ ] Proxmox API credentials set
  - [ ] Proxmox node name correct: `proxmox`
  - [ ] Talos version correct: `v1.12.1`
  - [ ] Control plane configured with 1 node on vmbr0 only
  - [ ] Worker nodes uncommented with correct configuration:
    - [ ] Workers attached ONLY to workload networks (vmbr1-4)
    - [ ] No vmbr0 attached to workers
    - [ ] Correct MAC addresses assigned
    - [ ] Network zones set correctly (trusted, dmz, untrusted, monitoring)
  - See [proxmox/terraform/terraform.tfvars](proxmox/terraform/terraform.tfvars) for reference

- [ ] **variables.tf**
  - [ ] Defines all required variables
  - [ ] Comments explain network isolation approach

- [ ] **Main Terraform Files**
  - [ ] `main.tf` - Provider configuration
  - [ ] `image.tf` - Talos ISO download
  - [ ] `nodes.tf` - VM definitions
  - [ ] `talos.tf` - Talos machine configuration generation

### Talos Configuration ✓

- [ ] **Generated Talos Configs**
  - [ ] Control plane config: `proxmox/terraform/talos/gen/talos-controlplane-1.yaml`
  - [ ] Talosconfig: `proxmox/terraform/talos/gen/talosconfig`
  - [ ] Location set in terraform output
  - See [proxmox/terraform/talos/manifests/README.md](proxmox/terraform/talos/manifests/README.md) for structure

- [ ] **Worker LinkConfig Manifests** (Talos 1.12 syntax)
  - [ ] `talos-worker-trusted-1/linkconfig.yaml`
  - [ ] `talos-worker-dmz-1/linkconfig.yaml`
  - [ ] `talos-worker-untrusted-1/linkconfig.yaml`
  - [ ] `talos-worker-monitoring-1/linkconfig.yaml`
  - [ ] Each has correct format:
    ```yaml
    apiVersion: net.talos.dev/v1alpha1
    kind: LinkConfig
    spec:
      addresses:
        - address: 10.10.x.21/24
      routes:
        - destination: 0.0.0.0/0
          gateway: 10.10.x.1
        - destination: 192.168.123.0/24
          gateway: 10.10.x.1
    ```

## Bootstrapping Checklist

### Phase 1: Cluster Bootstrap

#### Step 1: Create Infrastructure
- [ ] Review Terraform plan
  ```bash
  cd proxmox/terraform
  terraform plan
  ```
- [ ] Apply Terraform configuration
  ```bash
  terraform apply
  ```
- [ ] VMs created in Proxmox
  - [ ] Control plane VM created (VMID 200)
  - [ ] Worker VMs created (VMID 220-223)
  - [ ] All VMs have correct network bridges attached

#### Step 2: Boot Nodes
- [ ] Set up admin machine static routes (see [BOOTSTRAP_GUIDE.md - Step 1](docs/BOOTSTRAP_GUIDE.md#step-1-add-static-routes-on-admin-machine))
- [ ] Start control plane VM: `qm start 200`
- [ ] Verify SSH access: `ssh talosctl@192.168.123.20`
- [ ] Start worker VMs: `qm start 220 221 222 223`
- [ ] For each worker, configure static IP via Proxmox console:
  - [ ] Open Proxmox web UI → select worker → Console tab
  - [ ] When Talos boots, press 'c' for dashboard/console access
  - [ ] Set static IP per the table in Step 3a:
    - Trusted: 10.10.20.21/24 gateway 10.10.20.1
    - DMZ: 10.10.30.21/24 gateway 10.10.30.1
    - Untrusted: 10.10.40.21/24 gateway 10.10.40.1
    - Monitoring: 10.10.50.21/24 gateway 10.10.50.1
  - [ ] Boot worker and verify console shows "Endpoint: 10.10.x.21"

#### Step 3: Apply Talos Configuration
- [ ] Set environment variables
  ```bash
  export TALOSCONFIG=~/.talos/config
  export KUBECONFIG=~/.kube/config
  ```
- [ ] Boot control plane and verify SSH access
  ```bash
  qm start 200
  ssh talosctl@192.168.123.20
  exit
  ```
- [ ] Boot all worker VMs
  ```bash
  qm start 220 221 222 223
  ```
- [ ] Apply control plane config
  ```bash
  talosctl apply-config \
    --insecure \
    --nodes 192.168.123.20 \
    --file ./proxmox/terraform/talos/gen/talos-controlplane-1.yaml
  ```
- [ ] Wait for control plane to reboot (~2 minutes)
- [ ] Configure talosctl to use control plane as bastion
  ```bash
  talosctl config endpoint 192.168.123.20
  talosctl config node 192.168.123.20
  ```
- [ ] Apply worker configs via bastion tunnel (talosctl routes through control plane)
  ```bash
  talosctl apply-config --insecure --nodes 10.10.20.21 --file ./manifests/talos-worker-trusted-1.yaml
  talosctl apply-config --insecure --nodes 10.10.30.21 --file ./manifests/talos-worker-dmz-1.yaml
  talosctl apply-config --insecure --nodes 10.10.40.21 --file ./manifests/talos-worker-untrusted-1.yaml
  talosctl apply-config --insecure --nodes 10.10.50.21 --file ./manifests/talos-worker-monitoring-1.yaml
  ```
- [ ] Wait for workers to reboot and install (~2-3 minutes each)

#### Step 4: Bootstrap Kubernetes
- [ ] Bootstrap the cluster
  ```bash
  talosctl bootstrap --nodes 192.168.123.20 --endpoints 192.168.123.20
  ```
- [ ] Get kubeconfig
  ```bash
  talosctl kubeconfig -n 192.168.123.20 -o kubeconfig.yaml
  export KUBECONFIG=$PWD/kubeconfig.yaml
  ```

#### Step 5: Wait for Cluster Readiness
- [ ] Monitor control plane readiness
  ```bash
  kubectl get nodes -w
  ```
- [ ] Expected initial state: All nodes show `NotReady` (CNI not installed yet)
- [ ] Wait 2-3 minutes for Cilium to stabilize

### Phase 2: Install Core Components

#### Step 5a: Install Cilium CNI
- [ ] Add Helm repository
  ```bash
  helm repo add cilium https://helm.cilium.io
  helm repo update
  ```
- [ ] Install Cilium
  ```bash
  helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=192.168.123.20 \
    --set k8sServicePort=6443 \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true
  ```
- [ ] Wait for CNI pods to be ready
  ```bash
  kubectl -n kube-system wait --for=condition=ready pod -l k8s-app=cilium --timeout=300s
  ```
- [ ] Verify all nodes now show `Ready`
  ```bash
  kubectl get nodes
  ```
- [ ] See [docs/CILIUM_HUBBLE_SETUP.md](docs/CILIUM_HUBBLE_SETUP.md) for detailed configuration

#### Step 5b: Install MetalLB
- [ ] Add Helm repository
  ```bash
  helm repo add metallb https://metallb.universe.tf
  helm repo update
  ```
- [ ] Install MetalLB
  ```bash
  helm install metallb metallb/metallb --namespace metallb-system --create-namespace
  ```
- [ ] Configure IP pool (192.168.123.21-29 on management network)
  ```bash
  kubectl apply -f - <<EOF
  apiVersion: metallb.io/v1beta1
  kind: IPAddressPool
  metadata:
    name: management-pool
    namespace: metallb-system
  spec:
    addresses:
    - 192.168.123.21-192.168.123.29
    autoAssign: true
  ---
  apiVersion: metallb.io/v1beta1
  kind: L2Advertisement
  metadata:
    name: management-advertisement
    namespace: metallb-system
  spec:
    ipAddressPools:
    - management-pool
  EOF
  ```
- [ ] Verify MetalLB is running
  ```bash
  kubectl -n metallb-system get pods
  ```

#### Step 5c: Install Sealed Secrets
- [ ] Add Helm repository
  ```bash
  helm repo add sealed-secrets https://helm.sealedsecrets.dev
  helm repo update
  ```
- [ ] Install Sealed Secrets
  ```bash
  helm install sealed-secrets sealed-secrets/sealed-secrets \
    --namespace kube-system \
    --set commandArgs[0]='--update-status=true'
  ```
- [ ] Wait for operator to be ready
  ```bash
  kubectl -n kube-system wait --for=condition=ready pod -l app.kubernetes.io/name=sealed-secrets --timeout=60s
  ```
- [ ] Extract and backup sealing key
  ```bash
  kubectl -n kube-system get secret sealed-secrets-keys \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > sealing-key.crt
  ```
  ⚠️ **IMPORTANT:** Store this key securely (Vaultwarden, encrypted backup, etc.)

### Phase 3: GitOps Setup

#### Step 6: Install Flux CD
- [ ] Install Flux CLI: `curl -s https://fluxcd.io/install.sh | sudo bash`
- [ ] Bootstrap Flux CD
  ```bash
  flux bootstrap github \
    --owner=<your-github-username> \
    --repo=homelab \
    --branch=main \
    --path=./flux
  ```
- [ ] Verify Flux is installed
  ```bash
  flux get all --all-namespaces
  ```

#### Step 7: Create Initial Flux Kustomization
- [ ] Create flux directory structure
  ```bash
  mkdir -p flux/{infrastructure,apps}
  ```
- [ ] Create Kustomization for infrastructure components
  - [ ] Cilium (already installed, create HelmRelease for future upgrades)
  - [ ] MetalLB (create HelmRelease)
  - [ ] Sealed Secrets (create HelmRelease)
- [ ] Push to Git
  ```bash
  git add flux/
  git commit -m "Initial Flux configuration"
  git push
  ```

### Phase 4: Application Deployment

#### Step 8: Deploy Traefik Ingress
- [ ] Create Traefik HelmRelease in `flux/infrastructure/traefik-helmrelease.yaml`
- [ ] Configure ACME resolver for Let's Encrypt
- [ ] Apply via Flux or manual kubectl apply for testing

#### Step 9: Deploy Applications
- [ ] Create application manifests in `flux/apps/`
- [ ] Use SealedSecrets for sensitive data
- [ ] Apply network policies via CiliumNetworkPolicy resources

## Testing Checklist

### Network Connectivity Tests ✓

- [ ] **Admin Machine to Cluster**
  - [ ] Ping control plane: `ping 192.168.123.20`
  - [ ] Ping workers via workload IPs: `ping 10.10.30.21`
  - [ ] Access Kubernetes API: `kubectl cluster-info`

- [ ] **Control Plane to Workers**
  - [ ] Check node status: `kubectl get nodes -o wide`
  - [ ] All nodes should show `Ready` status

- [ ] **Pod-to-Pod Networking**
  - [ ] Create test pod: `kubectl run test --image=busybox -- sleep 3600`
  - [ ] Test DNS: `kubectl exec test -- nslookup kubernetes.default`
  - [ ] Test inter-pod communication (if multiple pods)

- [ ] **External Connectivity**
  - [ ] Create test LoadBalancer service
  - [ ] Verify MetalLB assigns IP: `kubectl get svc`
  - [ ] Test access from home LAN machine

### Security Tests ✓

- [ ] **Network Policies**
  - [ ] Default-deny policy installed
  - [ ] Test that pods can't communicate without explicit policy
  - [ ] Test that allowed communication works

- [ ] **Sealed Secrets**
  - [ ] Create a secret and seal it
  - [ ] Verify sealed secret can be decrypted by controller
  - [ ] Verify original secret is not exposed in Git

## Troubleshooting Checklist

See [docs/BOOTSTRAP_GUIDE.md - Troubleshooting](docs/BOOTSTRAP_GUIDE.md#troubleshooting) for detailed troubleshooting steps.

### Common Issues

- [ ] **SSH bastion connection fails**
  - Check: Control plane is fully booted (wait 2-3 minutes after "Endpoint" message)
  - Check: SSH key-based auth configured if needed
  - Check: No firewall blocking SSH port 22
  - See: [BOOTSTRAP_GUIDE.md - Bastion Connection Troubleshooting](docs/BOOTSTRAP_GUIDE.md#troubleshooting)

- [ ] **talosctl commands timeout targeting workers**
  - Check: Control plane is accessible and configured as endpoint
  - Check: Worker IPs are correct (verify in Proxmox console)
  - Check: talosctl config endpoint and node are set to control plane
  - See: [BOOTSTRAP_GUIDE.md - talosctl Bastion Routing](docs/BOOTSTRAP_GUIDE.md#troubleshooting)

- [ ] **Nodes stuck in NotReady**
  - Check: Cilium CNI pods are running
  - Check: Control plane logs for errors
  - See: [BOOTSTRAP_GUIDE.md - Worker Nodes Stuck in NotReady](docs/BOOTSTRAP_GUIDE.md#troubleshooting)

- [ ] **LoadBalancer services pending**
  - Check: MetalLB pool configuration
  - Check: MetalLB speaker pod logs
  - See: [BOOTSTRAP_GUIDE.md - LoadBalancer Service Stuck in Pending](docs/BOOTSTRAP_GUIDE.md#troubleshooting)

## Documentation Reference

| Document | Purpose |
|----------|---------|
| [README.md](README.md) | Main architecture and setup overview |
| [proxmox/host/NETWORK_SETUP.md](proxmox/host/NETWORK_SETUP.md) | Proxmox host networking configuration |
| [proxmox/terraform/README.md](proxmox/terraform/README.md) | Terraform IaC documentation |
| [docs/BOOTSTRAP_GUIDE.md](docs/BOOTSTRAP_GUIDE.md) | Step-by-step cluster bootstrap procedure |
| [docs/CILIUM_HUBBLE_SETUP.md](docs/CILIUM_HUBBLE_SETUP.md) | Cilium CNI and Hubble installation |
| [SETUP_CHECKLIST.md](SETUP_CHECKLIST.md) | This file - comprehensive setup verification |

## Completion Checklist

Mark this section as complete when the entire cluster is bootstrapped and ready for applications:

- [ ] All prerequisites verified
- [ ] Terraform infrastructure created
- [ ] Talos cluster bootstrapped
- [ ] All nodes showing `Ready` status
- [ ] Cilium, MetalLB, and Sealed Secrets installed
- [ ] Flux CD configured (optional but recommended)
- [ ] Network policies applied (optional but recommended)
- [ ] Test applications deployed successfully
- [ ] External access working via Traefik/MetalLB

**Status:** Setup complete and cluster ready for production workloads ✓
