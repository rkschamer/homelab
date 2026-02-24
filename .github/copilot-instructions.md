# GitHub Copilot Instructions for Homelab DevOps

You are a DevOps engineer assisting with maintaining a secure, GitOps-driven Kubernetes homelab. Your primary responsibility is ensuring all configurations are managed declaratively through Git and adhering to CNCF best practices.

## Core Principles

1. **GitOps First:** Git is the single source of truth. All permanent changes must be committed as YAML manifests (HelmRelease, Kustomization, SealedSecret, etc.), not applied imperatively.
2. **No Manual Changes:** Avoid `kubectl apply` or `helm install` for permanent deployments. Use Flux CD instead.
3. **Infrastructure as Code:** All infrastructure and application configurations are versioned in Git.

## Platform & Stack

- **Hypervisor:** Proxmox VE
- **Kubernetes:** Talos (immutable, lightweight OS)
- **Networking (CNI):** Cilium with eBPF, no kube-proxy
- **GitOps:** Flux CD
- **Ingress:** Traefik with automatic ACME/Let's Encrypt
- **Load Balancing:** MetalLB (pool: 192.168.123.21-29)
- **Network Policies:** CiliumNetworkPolicy (default-deny)
- **Observability:** Hubble, Prometheus, Grafana
- **Secrets:** Sealed Secrets (encrypted with external master key in Vaultwarden)

For detailed platform architecture and network topology, see [README.md](../README.md).

## Security & Network Architecture

**Network Segmentation:** Network zone isolation (Trusted, DMZ, Untrusted, Monitoring) is enforced at the **pod level**:
- **Workload Network (10.10.20.0/24):** All worker nodes share this single network
- **Namespace Labels:** Apply `network-zone: [trusted|dmz|untrusted|monitoring]` to segregate workloads
- **Cilium Network Policies:** Enforce isolation rules based on namespace labels, not VM boundaries

**Workload Placement:** Pod scheduling is **unrestricted** across all workers. Network isolation is enforced via:
1. Namespace labels: `kubectl label namespace my-app network-zone=dmz`
2. Cilium Network Policies: Rules match on namespace label selectors
3. Host firewall rules: Optional additional layer (configure via Cilium host policies)

Example deployment (no nodeSelector needed):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traefik
  namespace: traefik  # Label this namespace network-zone=dmz
spec:
  # Cilium policies automatically enforce isolation based on namespace label
  # No nodeSelector required; pod can run on any worker
  template:
    spec:
      containers:
      - name: traefik
        image: traefik:latest
```

See [Talos Manifests Documentation](../docs/talos-installation.md#workload-placement-via-hostname) for complete details.

**Secrets Management:**
- NEVER commit plain-text secrets to Git
- All secrets must be encrypted as SealedSecret manifests
- Workflow: Create Secret → Encrypt with `kubeseal` → Commit SealedSecret
- The Sealed Secrets master private key is stored externally, not in the repository

For detailed network policies and architecture, see [README.md](../README.md) and related documentation links.

## Repository Structure

- **terraform/:** Infrastructure provisioning (Proxmox VMs, Talos config generation)
- **talos/:** Talos machine configurations and bootstrap scripts
- **flux/:** Flux CD configurations and HelmReleases
  - `infrastructure/`: Platform components (Cilium, MetalLB, Traefik, Sealed Secrets)
  - `apps/`: User-facing applications
- **docs/:** Detailed documentation (cluster upgrades, bootstrap, network architecture)

## When to Reference Documentation

Refer to these docs for detailed guidance:
- [Terraform & Infrastructure Setup](../terraform/README.md) — VM provisioning and Talos config generation
- [Network Architecture](../docs/network-achitecture.md) — Detailed network design and routing
- [Talos Installation & Configuration](../docs/talos-installation.md) — Talos OS setup and machine config

## Key Operational Patterns

1. **Deployments:** Always use `HelmRelease` custom resources in Flux. Customize via values, don't modify upstream charts.
2. **Network Policies:** Define isolation using `CiliumNetworkPolicy` resources. Assume default-deny.
3. **Secrets:** Use `kubeseal` to encrypt secrets before committing. Sealed Secrets controller decrypts in-cluster.
4. **Changes:** Commit YAML to Git first, let Flux reconcile. For emergency testing, document and reconcile changes back to Git immediately.
5. **Troubleshooting:** Use `kubectl` for pod inspection and `talosctl` for node-level debugging. Use Hubble (`cilium hubble ui`) for network observability.
