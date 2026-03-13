# MetalLB Config Kustomization

This directory contains MetalLB custom resources that require MetalLB CRDs:

- `IPAddressPool`
- `L2Advertisement`

## Why This Is Separate

Flux dry-runs manifests before apply. If `IPAddressPool` and `L2Advertisement` are in the same reconciliation set as the `HelmRelease`, the dry-run can fail before the chart has installed MetalLB CRDs.

Resulting error:

- `no matches for kind "IPAddressPool" in version "metallb.io/v1beta1"`

To avoid this, we reconcile these resources via a separate Flux `Kustomization` (`metallb-config`) defined in `flux/infrastructure/metallb-release.yaml`.

## Reconciliation Flow

1. `metallb-release.yaml` applies `HelmRepository`, `Namespace`, and `HelmRelease`.
2. The MetalLB chart installs CRDs.
3. The separate `metallb-config` Flux `Kustomization` reconciles this directory.
4. `IPAddressPool` and `L2Advertisement` apply successfully once CRDs are present.
