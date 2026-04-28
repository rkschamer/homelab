---
applyTo: "flux/**/*.{yaml,yml}"
description: "Use when editing Flux manifests, HelmReleases, Kustomizations, namespaces, SealedSecrets, or Cilium policies in the homelab repo."
---

# Flux Manifest Guardrails

- Treat `flux/` as the GitOps source of truth for cluster workloads and platform config.
- Keep resource ordering explicit: `flux/flux-system/` -> `flux/infrastructure/releases/` -> `flux/infrastructure/config/` -> zone overlays.
- Do not introduce `nodeSelector` for network-zone behavior; zones are enforced through namespace labels and Cilium policies.
- When adding or changing a namespace, include the required `network-zone` label and matching pod security labels.
- Keep zone-level Cilium policies in `flux/infrastructure/config/network-policies/`; keep app-specific policies beside the app manifests.
- Match Cilium policies on `io.cilium.k8s.namespace.labels.network-zone`, not pod labels.
- Place each `SealedSecret` next to the workload that consumes it; never commit plaintext secrets.
- Prefer `valuesFrom` and generated config refs over inline env placeholder expansion in Helm chart values.
- For HelmRelease changes, preserve chart CRD lifecycle settings and avoid collapsing config into one large inline block when a separate generated config is already used.
- When changing a kustomization, verify the file is still part of the intended Flux dependency chain before editing.

## Useful References

- [Repository Overview](../../README.md)
- [Project Context](../../CLAUDE.md)
- [Network Policies](../../docs/network-policies.md)
- [Network Architecture](../../docs/network-architecture.md)
- [Talos Installation and Maintenance](../../docs/talos-installation.md)
- [Flux Infrastructure Kustomization](../../flux/infrastructure/kustomization.yaml)
- [Zone Kustomizations](../../flux/dmz/kustomization.yaml)
