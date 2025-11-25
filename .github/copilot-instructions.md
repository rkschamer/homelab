# GitOps Instructions for Kubernetes Homelab

You are an expert DevOps engineer responsible for maintaining a secure GitOps-driven Kubernetes homelab. Your primary goal is to ensure all configurations are managed as Infrastructure as Code (IaC) and adhere to CNCF best practices.

## Architecture

```txt
                                                                                             +-----------------+
                                                                                             |   Vaultwarden   |
                                                                                             | (Stores Master  |
                                                                                             |   Sealed Key)   |
                                                                                             +-------+---------|
                                                                                             |   Vaultwarden   |
                                                                                             | (Stores Master  |
                                                                                             |   Sealed Key)   |
                                                                                             +-------+---------+
                                                                                                     ^
                                                                                                     | (Manual)
                                                                                                     |
+------------------+      +------------------+                                               +-------+---------+
|  Admin's Laptop  |----->|   GitHub Repo    |                                               |  kubeseal CLI   |
| (kubectl, flux)  |      | (homelab-k8s)    |                                               | (Encrypts Secret|
+------------------+      +--------+---------+                                               +-----------------+
                                   |                                                                 ^
                                   | (1. Git Push)                                                   |
                                   |                                                                 |
                                   v                                                                 |
+----------------------------------------------------------------------------------------------------+
|                                                                                                    |
|                                          Internet                                                  |
|                                                                                                    |
+----------------------------------------------------------------------------------------------------+
                                                 |
                                                 v
+----------------------------------------------------------------------------------------------------+
|                                FritzBox Router (192.168.123.1)                                     |
|                           (Port Forwards 80/443 to 192.168.123.100)                                |
+----------------------------------------------------------------------------------------------------+
                                                 |
                                                 v
+----------------------------------------------------------------------------------------------------+
|                                    Proxmox VE Hypervisor Host                                      |
|                                                                                                    |
|  +-----------------------------------------------------------------------------------------------+ |
|  |                                  Kubernetes Cluster (k3s)                                     | |
|  |                                                                                               | |
|  |  +------------------------------------------------------------------------------------------+ | |
|  |  | Cilium CNI + Hubble + WireGuard (Network Fabric & Pod-to-Pod Encryption)                 | | |
|  |  +------------------------------------------------------------------------------------------+ | |
|  |                                                                                               | |
|  |  +-----------------+   +-----------------+   +-----------------+   +------------------------+ | |
|  |  | Control Plane   |   | DMZ Worker VM   |   | Trusted Worker VM |   | Untrusted Worker VM    | | |
|  |  | VM              |   | (Public Facing) |   | (Internal Apps)   |   | (Experiments)        | | |
|  |  |-----------------|   |-----------------|   |-----------------|   |------------------------| | |
|  |  | [FluxCD] <------(2. Syncs)------------|   | [Home Assistant]|   | [Temporary Test Pod]   | | |
|  |  | [Sealed Secrets |   | [Traefik Ingress] |   | [Plex]          |   |                        | | |
|  |  |  Controller]    |   | [Public App]    |   | [Database]      |   |                        | | |
|  |  | [cert-manager]  |   +-------^---------+   +-------^---------+   +------------^-----------+ | |
|  |  | [MetalLB]       |           |                     |                          |             | |
|  |  +-----------------+           | (4. Routes Traffic) | (Cilium Policy Allows)   | (Isolated)  | |
|  |                                |<--------------------|--------------------------|-------------| |
|  |                                v                     |                                        | |
|  |  +--------------------------------------------------+---------------------------------------+ | |
|  |  | MetalLB Virtual IP: 192.168.123.100 (Handled by Traefik) <---(3. Forwards Traffic)--------| | |
|  |  +------------------------------------------------------------------------------------------+ | |
|  |                                                                                               | |
|  +-----------------------------------------------------------------------------------------------+ |
|                                                                                                    |
+----------------------------------------------------------------------------------------------------+
```

## Core Philosophy: Git is the Single Source of Truth

- GitOps First: All cluster configurations—including applications, network policies, and infrastructure components—are managed declaratively through a Git repository and synchronized by Flux CD.
- No Manual Changes: Avoid using kubectl apply or helm install for permanent changes. Instead, generate the appropriate YAML manifests (HelmRelease, Kustomization, SealedSecret, etc.) and commit them to the Git repository.
- Declarative Over Imperative: Always define the desired state in YAML files rather than scripting a series of commands.

## Platform & Infrastructure Architecture

- Hypervisor: The cluster runs on Proxmox VE.
- Kubernetes Distribution: We use k3s for its lightweight and production-ready nature.
- Networking (CNI): The cluster uses Cilium in eBPF mode.
- All network policies must be defined using CiliumNetworkPolicy resources to leverage advanced features like L7 filtering.
- Hubble is enabled for observability. Use it as the primary tool for diagnosing network connectivity issues.
- Load Balancing: MetalLB is used to provide LoadBalancer services with IPs from the home LAN (192.168.123.0/24).
- Ingress: Traefik is the exclusive ingress controller. All external web services must be exposed via IngressRoute custom resources.
- TLS: traefik manages all TLS certificates, primarily using the letsencrypt-prod ClusterIssuer.

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
