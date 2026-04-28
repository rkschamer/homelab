# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Kubernetes homelab running on Proxmox VE, managed declaratively using GitOps principles with Flux CD. The cluster uses Talos (immutable Kubernetes OS), Cilium CNI with eBPF, and enforces network isolation at the pod level using namespace labels and Cilium Network Policies.

## Core Principles

**GitOps First:** All permanent changes MUST be committed as YAML manifests and synced via Flux CD. Never use `kubectl apply` or `helm install` for permanent deployments.

**Infrastructure as Code:** All infrastructure (Proxmox VMs, Talos configurations, Kubernetes manifests) is versioned in Git.

**Secrets Management:** All secrets must be encrypted as SealedSecrets before committing. Never commit plaintext secrets. Secrets are decrypted in-cluster by the Sealed Secrets controller.

**Network Isolation:** Network zones (Trusted, DMZ, Untrusted, Monitoring) are enforced at the **pod level** via namespace labels (`network-zone: [trusted|dmz|untrusted|monitoring]`) and Cilium Network Policies, not via separate physical networks.

## Stack

- **Hypervisor:** Proxmox VE
- **Kubernetes OS:** Talos (v1.11.6+) - immutable, lightweight
- **CNI:** Cilium 1.19.1+ with eBPF, kube-proxy replacement enabled
- **GitOps:** Flux CD
- **Ingress:** Traefik with ACME/Let's Encrypt
- **Load Balancing:** MetalLB (pool: 192.168.123.21-29)
- **Observability:** Hubble (network), Prometheus, Loki, Fluent Bit
- **Secrets:** Sealed Secrets (master key stored externally in Vaultwarden)
- **Storage:** Longhorn (distributed block storage)

## Network Architecture

### Physical Networks

- **Management (vmbr0, 192.168.123.0/24):** Control plane only, connected to home LAN (FritzBox router)
- **Workload (vmbr1, 10.10.20.0/24):** All worker nodes share this single network

### Control Plane (192.168.123.20)

- Acts as bastion and router between management and workload networks
- IP forwarding enabled on all interfaces
- Connected to both vmbr0 (management) and vmbr1 (workload)
- Workers route management network traffic (192.168.123.0/24) through control plane interface at 10.10.20.2

### Worker Nodes

- All workers on same workload network (10.10.20.0/24)
- No physical network isolation between zones
- Pods can schedule on any worker (no nodeSelector required)
- Network isolation enforced via namespace labels + Cilium Network Policies

### Network Zones (Pod-Level Isolation)

Apply zone labels to namespaces:
```bash
kubectl label namespace <namespace> network-zone=<trusted|dmz|untrusted|monitoring>
```

| Zone | Label | Purpose | Connectivity |
|------|-------|---------|--------------|
| **Trusted** | `network-zone: trusted` | Internal services (Home Assistant, NAS) | Home LAN, Management, Internet |
| **DMZ** | `network-zone: dmz` | Public-facing (Traefik Ingress) | Internet, explicit Trusted pods; Blocked: Home LAN, Untrusted |
| **Untrusted** | `network-zone: untrusted` | Services needing no home network access; also experiments/sandboxing. Name reflects access level, not software trustworthiness. | Internet only; Blocked: all others |
| **Monitoring** | `network-zone: monitoring` | Observability (Prometheus, Grafana, Hubble) | Pull from all zones; others cannot push |

Cilium Network Policies in `flux/infrastructure/network-policies/` enforce these rules.

## Repository Structure

```
.
├── terraform/              # Infrastructure provisioning
│   ├── main.tf            # Proxmox provider config
│   ├── nodes.tf           # VM definitions (control plane + workers)
│   ├── talos.tf           # Talos config generation
│   ├── image.tf           # Talos ISO from Image Factory
│   └── terraform.tfvars   # Encrypted with git-crypt
├── talos/
│   ├── gen/               # Generated configs (talosconfig, kubeconfig, machine configs)
│   ├── manifests/         # Per-node LinkConfig manifests for network setup
│   └── bootstrap/         # Bootstrap scripts
├── flux/
│   ├── flux-system/       # Flux CD system components
│   ├── infrastructure/
│   │   ├── releases/           # HelmRelease manifests (Cilium, MetalLB, Longhorn, ...)
│   │   └── config/             # Post-install config (MetalLB pool, network policies, Longhorn)
│   │       └── network-policies/   # Cilium Network Policies for zone isolation
│   ├── dmz/               # DMZ zone services (Traefik, Authentik, CrowdSec)
│   ├── trusted/           # Trusted zone services (Vaultwarden, SiYuan)
│   ├── untrusted/         # Untrusted zone services (Pi-hole, Snowflake Proxy)
│   └── monitoring/        # Monitoring stack (Prometheus, Loki, Fluent Bit)
└── docs/                  # Detailed documentation
    ├── network-architecture.md
    ├── network-policies.md
    ├── talos-installation.md
    └── crowdsec.md
```

## Common Operations

### Decrypt Repository

This repo uses `git-crypt` to encrypt sensitive files (terraform.tfvars, kubeconfig, talosconfig):

```bash
git-crypt unlock /path/to/encryption-key
```

The encryption key is stored in Vaultwarden.

### Infrastructure Provisioning (Terraform)

```bash
cd terraform
terraform init
terraform plan
terraform apply

# After apply, remove ISO from VMs in Proxmox UI before configuring nodes
```

Terraform generates Talos machine configs in `talos/gen/` (controlplane.yaml, worker-*.yaml, talosconfig).

### Talos Configuration

Set environment variables:
```bash
export TALOSCONFIG="$(pwd)/talos/gen/talosconfig"
export KUBECONFIG="$(pwd)/talos/gen/kubeconfig"
```

Apply configs to nodes:
```bash
# Control plane (use DHCP IP from Proxmox console during first boot)
talosctl config endpoint <DHCP_IP>
talosctl apply-config --insecure --nodes <DHCP_IP> --file talos/gen/controlplane.yaml

# Bootstrap etcd
talosctl bootstrap

# Get kubeconfig
talosctl kubeconfig .

# Workers (repeat for each)
talosctl apply-config --insecure --nodes <DHCP_IP> --file talos/gen/worker-<name>.yaml
```

### Verify Cluster

```bash
kubectl get nodes
talosctl get members
kubectl get pods -A
```

### Check Cilium Status

```bash
cilium status
cilium connectivity test
hubble observe  # Network flow observability
```

### Manage Sealed Secrets

Create and encrypt secrets:
```bash
# Create normal secret
kubectl create secret generic my-secret --from-literal=key=value --dry-run=client -o yaml > secret.yaml

# Encrypt with kubeseal
kubeseal --format=yaml < secret.yaml > sealed-secret.yaml

# Commit sealed-secret.yaml to Git
git add sealed-secret.yaml
```

The Sealed Secrets controller automatically decrypts in-cluster.

### Flux Reconciliation

```bash
flux reconcile source git flux-system
flux reconcile kustomization flux-system
flux get all -A
```

### Network Troubleshooting

Check routing:
```bash
# Control plane routes
talosctl -n 192.168.123.20 get routes

# Worker routes (should include 192.168.123.0/24 via 10.10.20.2)
talosctl -n 10.10.20.21 get routes

# Check IP forwarding on control plane
talosctl read /proc/sys/net/ipv4/ip_forward --nodes 192.168.123.20
```

Network policy debugging:
```bash
kubectl get cnp -A  # List Cilium Network Policies
hubble observe --namespace <ns>  # Watch network flows
cilium monitor  # BPF program monitoring
```

### Cluster Upgrades

Always refer to `docs/talos-installation.md` for detailed procedures.

Talos OS upgrade:
```bash
talosctl upgrade --image ghcr.io/siderolabs/installer:v1.x.y --nodes <node-ip>
```

Kubernetes version upgrade:
```bash
talosctl upgrade-k8s --to 1.x.y
```

## Key Files

- **terraform.tfvars:** Contains Proxmox credentials and cluster configuration (encrypted)
- **talos/gen/talosconfig:** Talos client credentials (encrypted)
- **talos/gen/kubeconfig:** Kubernetes admin credentials (encrypted)
- **talos/manifests/<node-name>/linkconfig.yaml:** Per-node network configuration (static IPs, routes, DNS)
- **flux/infrastructure/releases/cilium-release.yaml:** Cilium CNI configuration
- **flux/infrastructure/config/network-policies/:** Zone isolation policies
- **.gitattributes:** Defines which files are encrypted by git-crypt

## Important Notes

### Workload Placement

Pods can schedule on **any worker** (no nodeSelector required). Network isolation is enforced via:
1. Namespace labels: `network-zone: [trusted|dmz|untrusted|monitoring]`
2. Cilium Network Policies matching on namespace labels
3. Optional host firewall rules (Cilium host policies)

### Static Routes on Workers

Workers include a critical static route for management network access:
```yaml
routes:
  - destination: 192.168.123.0/24
    gateway: 10.10.20.2  # Control plane workload interface
```

This ensures workers can reach the management network (for control plane API, admin access) via the bastion.

### Cilium Configuration

- **kube-proxy replacement:** Enabled (kube-proxy not deployed)
- **Routing mode:** tunnel (VXLAN)
- **Host firewall:** Enabled for pod-to-pod isolation
- **Policy enforcement mode:** default (endpoints allow all until selected by policy)
- **Identity-relevant labels:** Include `node-role.kubernetes.io/*` for host firewall node selection

### MetalLB Pool

LoadBalancer services receive IPs from 192.168.123.21-29 (management network). FritzBox router forwards ports 80/443 to this range.

### Documentation References

For deep dives, consult:
- `README.md` - Project overview and service inventory
- `docs/network-architecture.md` - Complete network design and routing
- `docs/network-policies.md` - Cilium policy details
- `docs/talos-installation.md` - Installation, bootstrap, and upgrade procedures
- `docs/crowdsec.md` - CrowdSec threat detection setup
- `terraform/README.md` - Terraform workflow and ISO-based deployment
- `talos/manifests/README.md` - LinkConfig and network configuration

## External References

- Talos Documentation: https://docs.siderolabs.com/talos
- Cilium Documentation: https://docs.cilium.io/
- Flux CD Documentation: https://fluxcd.io/docs/
- Sealed Secrets: https://github.com/bitnami-labs/sealed-secrets
