# GitHub Copilot Instructions for Homelab DevOps

Use this repository as the single source of truth for a GitOps-managed Kubernetes homelab.

## Non-Negotiables

1. **GitOps first:** permanent changes must be committed in Git as manifests and reconciled by Flux.
2. **No imperative drift:** do not use `kubectl apply` or `helm install` for permanent deployments.
3. **Secrets safety:** never commit plaintext secrets; commit only `SealedSecret` manifests.
4. **Pod-level zone isolation:** apply namespace label `network-zone: trusted|dmz|untrusted|monitoring` and enforce with `CiliumNetworkPolicy`.
5. **No zone-based node pinning:** do not use `nodeSelector` to model zones; workloads may run on any worker.

## Repository Ownership Map

| Path | Purpose | Agent behavior |
| --- | --- | --- |
| `terraform/` | Proxmox VM provisioning and Talos config generation | Source of infra truth; run Terraform here |
| `talos/gen/` | Generated Talos configs and kubeconfig (encrypted) | Treat as generated artifacts; regenerate via Terraform |
| `talos/manifests/` | Per-node LinkConfig network manifests | Keep routes and node networking consistent |
| `talos/bootstrap/` | One-time cluster bootstrap scripts | Use for initial Cilium/Flux bootstrap only |
| `flux/infrastructure/releases/` | Platform HelmReleases (Cilium, MetalLB, Longhorn, etc.) | Reconcile platform first |
| `flux/infrastructure/config/` | Post-install config (policies, pools, classes) | Keep zone policy logic here |
| `flux/dmz/`, `flux/trusted/`, `flux/untrusted/`, `flux/monitoring/` | Zone workloads | Ensure namespace label and policy alignment |
| `docs/` | Architecture and runbooks | Link to docs instead of duplicating details |

## Required Change Workflow

1. Edit manifests in the correct Flux/Talos/Terraform path.
2. For new namespaces, add `network-zone` label and matching policy coverage.
3. For credentials, generate a Secret and seal it with `kubeseal`; commit only sealed output.
4. Commit changes and allow Flux to reconcile.
5. Validate cluster and policy state with the commands below.

## Quick Validation Commands

```bash
export TALOSCONFIG="$(pwd)/talos/gen/talosconfig"
export KUBECONFIG="$(pwd)/talos/gen/kubeconfig"

kubectl get nodes
flux get all -A
kubectl get cnp -A
cilium status
```

## Known Pitfalls

- **Authelia OIDC values path:** use `values.configMap.identity_providers.oidc` (not `values.identity_providers.oidc`).
- **Alertmanager env placeholders:** `${SMTP_*}` placeholders in Alertmanager config fail operator validation; provide fully rendered config via SealedSecret.
- **Grafana dashboard key:** use `gnetId` (not `gnet_id`) for Grafana.com dashboards.
- **Worker management route:** workers need route `192.168.123.0/24 -> 10.10.20.2` to reach management network through control plane.
- **Encrypted files:** unlock git-crypt before editing encrypted files.

## Canonical References

- [Repository Overview](../README.md)
- [Project Context](../CLAUDE.md)
- [Network Architecture](../docs/network-architecture.md)
- [Network Policies](../docs/network-policies.md)
- [Talos Installation and Maintenance](../docs/talos-installation.md)
- [Terraform Workflow](../terraform/README.md)
- [Talos Manifests](../talos/manifests/README.md)
