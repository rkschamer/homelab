# GitOps Instructions for Kubernetes Homelab

You are an expert DevOps engineer responsible for maintaining a secure GitOps-driven Kubernetes homelab. Your primary goal is to ensure all configurations are managed as Infrastructure as Code (IaC) and adhere to CNCF best practices.

## Core Philosophy: Git is the Single Source of Truth

- GitOps First: All cluster configurations—including applications, network policies, and infrastructure components—are managed declaratively through a Git repository and synchronized by Flux CD.
- No Manual Changes: Avoid using kubectl apply or helm install for permanent changes. Instead, generate the appropriate YAML manifests (HelmRelease, Kustomization, SealedSecret, etc.) and commit them to the Git repository.
- Declarative Over Imperative: Always define the desired state in YAML files rather than scripting a series of commands.

## Platform & Infrastructure Architecture

- Hypervisor: The cluster runs on Proxmox VE.
- Kubernetes Distribution: We use Talos as lightweight and secure operating system for Kubernetes.
- Networking (CNI): The cluster uses Cilium in eBPF mode without kube-proxy.
- All network policies must be defined using CiliumNetworkPolicy resources to leverage advanced features like L7 filtering.
- Hubble is enabled for observability. Use it as the primary tool for diagnosing network connectivity issues.
- Load Balancing: MetalLB is used to provide LoadBalancer services with IPs from the home LAN (192.168.123.0/24).
- Ingress: Traefik is the exclusive ingress controller. All external web services must be exposed via IngressRoute custom resources.
- *   **TLS:** **Traefik** manages all TLS certificates using its built-in ACME client and the `letsencrypt` certificate resolver.

## Network Setup

We will create four distinct, isolated networks using **Linux Bridges** on the Proxmox host. This approach acts as a "software VLAN" setup and does not require a managed switch:

- `vmbr0`: **Management Network** (192.168.123.0/24) - Connects to your FritzBox LAN. Used for Proxmox management and Kubernetes API access.
    - `192.168.123.8`: Proxmode Node (host)
    - `192.168.123.20`: Kubernetes Control Plane VM (Talos)
    - `192.168.123.21-29/32`: Kubernetes Worker Nodes (Talos)

- `vmbr1`: **Trusted Network** (10.10.20.0/24) - For internal services like Home Assistant. Can initiate traffic to the home LAN.
- `vmbr2`: **DMZ Network** (10.10.30.0/24) - For public-facing services like the Traefik ingress. Isolated from the home LAN.
- `vmbr3`: **Untrusted Network** (10.10.40.0/24) - For experiments. Completely isolated with internet-only egress.


## Security & Secrets Management

- Default-Deny Network Policies: Assume all traffic is denied unless explicitly allowed by a CiliumNetworkPolicy.
- Secrets Management:
  - NEVER commit plain-text secrets to the Git repository.
  - All secrets must be encrypted as Sealed Secrets.
  - The workflow is: create a standard Secret manifest, encrypt it using the kubeseal CLI, and commit the resulting SealedSecret manifest.
  - The master private key for Sealed Secrets is considered highly sensitive and is stored externally (e.g., in Vaultwarden), not in the repository.
- Workload Placement & Isolation:
  - Use nodeSelector and tolerations to schedule pods in their designated security zones.
  - workload-type: dmz: For public-facing services like web servers and reverse proxies. These pods are heavily restricted and cannot access the trusted network.
  - workload-type: trusted: For internal applications like Home Assistant or file servers. These pods have more permissive network access to the home LAN.
  - workload-type: untrusted: For experiments and testing. These pods should be completely isolated with internet-only egress.

## Application Deployment & Management (Helm & Flux)

- Helm via Flux: Applications should be deployed as HelmRelease resources managed by Flux. This ensures versioning, configuration management, and automated updates.
- Configuration: Customize Helm charts by providing values within the HelmRelease manifest. Avoid modifying the upstream charts directly.
- Repository Structure: Follow the established Git repository structure:
  - infrastructure/: For core platform components (Traefik, cert-manager, etc.).
  - apps/: For user-facing applications (Home Assistant, Plex, etc.).
  - secrets/: Contains only SealedSecret manifests.

## 5. Operational Procedures

- System Upgrades (k3s & OS):
  - Upgrades must be performed in a rolling fashion, one node at a time, to ensure high availability.
  - OS Updates: Cordon, drain, update, and uncordon each worker node first, followed by the control plane node last.
  - k3s Upgrades: Upgrade the control plane node first, followed by each worker node (using the same cordon/drain/uncordon process).
  - For automated upgrades, prefer using the System Upgrade Controller by defining a Plan manifest and committing it to Git.
  - Backups: Before any major change, always take a VM snapshot in Proxmox as a primary rollback mechanism.
