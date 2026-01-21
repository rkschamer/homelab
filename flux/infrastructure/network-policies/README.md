# Network Policies Directory Structure

This directory contains organized CiliumNetworkPolicy resources for the homelab Kubernetes cluster, organized by node and policy type.

## Structure

```
network-policies/
├── clusterwide-policies.yaml       # Global policies (default deny, DNS)
├── system-policies.yaml            # System component policies (Flux, Cilium, MetalLB, etc)
├── kustomization.yaml              # Kustomize manifest for all policies
│
├── talos-controlplane-1/           # Control plane node specific
│   └── host-firewall.yaml
│
├── talos-worker-dmz-1/             # DMZ worker (public-facing)
│   └── dmz-policies.yaml
│
├── talos-worker-trusted-1/         # Trusted worker (internal services)
│   └── trusted-policies.yaml
│
├── talos-worker-untrusted-1/       # Untrusted worker (experimental)
│   └── untrusted-policies.yaml
│
└── talos-worker-monitoring-1/      # Monitoring worker (observability)
    └── monitoring-policies.yaml
```

## File Organization

### Global Policies

**`clusterwide-policies.yaml`**
- `default-deny-ingress` - Cluster-wide zero-trust foundation (deny all ingress by default)
- `default-allow-dns` - Allow DNS queries cluster-wide

**`system-policies.yaml`**
- `allow-flux-system-internal` - Flux GitOps components
- `allow-kube-system-metrics` - Prometheus scraping system metrics
- `allow-cilium-internal` - Cilium CNI agent communication
- `allow-hubble-ui` - Hubble observability dashboard
- `allow-metallb` - MetalLB load balancer
- `allow-sealed-secrets` - Sealed Secrets controller

### Per-Node Policies

**`talos-controlplane-1/host-firewall.yaml`**
- `host-firewall-control-plane` - Protects control plane from pod-level threats

**`talos-worker-dmz-1/dmz-policies.yaml`**
- `allow-traefik-dmz` - Allow external traffic ingress
- `allow-dmz-to-trusted` - Allow forwarding to Trusted backends
- `deny-dmz-to-untrusted` - Enforce strict isolation from Untrusted
- `host-firewall-dmz-worker` - DMZ worker node protection

**`talos-worker-trusted-1/trusted-policies.yaml`**
- `allow-trusted-network-pods` - Pod-to-pod communication within zone
- `host-firewall-trusted-worker` - Trusted worker node protection

**`talos-worker-untrusted-1/untrusted-policies.yaml`**
- `allow-untrusted-network-pods` - Internal communication only
- `host-firewall-untrusted-worker` - Untrusted worker node protection

**`talos-worker-monitoring-1/monitoring-policies.yaml`**
- `allow-monitoring-scrape` - Prometheus metrics collection
- `allow-grafana-dashboards` - Grafana access from management network
- `allow-monitoring-cross-zone-scrape` - Cross-zone metrics collection
- `host-firewall-monitoring-worker` - Monitoring worker node protection

## Policy Application

Policies are applied in this order (via `kustomization.yaml`):

1. **Global foundation** → `clusterwide-policies.yaml`
2. **System components** → `system-policies.yaml`
3. **Node-specific** → Each node's folder policies

This ensures:
- Default deny is established first
- System services can operate
- Node-specific policies layer on top

## Adding New Policies

### For a Specific Node

1. Add policy to existing node folder (e.g., `talos-worker-dmz-1/dmz-policies.yaml`)
2. Or create new file in node folder if policies grow large:
   ```
   talos-worker-dmz-1/
   ├── dmz-policies.yaml
   ├── traefik-ingress-rules.yaml   # New
   └── custom-app-policies.yaml     # New
   ```
3. Update `kustomization.yaml` to include new file

### For a New System Component

1. Add policy to `system-policies.yaml` with comment explaining purpose
2. Or create new file if component deserves dedicated section:
   ```
   system-policies.yaml
   component-name-policies.yaml  # New
   ```

### For a New Worker Node

1. Create folder: `talos-worker-<name>/`
2. Create policies file: `talos-worker-<name>/<name>-policies.yaml`
3. Add to `kustomization.yaml`:
   ```yaml
   resources:
     # ... existing
     - talos-worker-<name>/<name>-policies.yaml
   ```

## Verification

Verify policies are properly configured:

```bash
# Check policies are loaded
kubectl get cnp -A
kubectl get ccnp

# Validate using provided script
../../../scripts/validate-cilium-policies.sh

# Monitor live with Hubble
cilium hubble observe --follow
```

## References

- [CiliumNetworkPolicy Documentation](https://docs.cilium.io/en/latest/security/policy/)
- [Comprehensive Policy Guide](../../../docs/CILIUM_NETWORK_POLICIES.md)
- [Pod Deployment Patterns](../../../docs/CILIUM_POD_DEPLOYMENT_PATTERNS.md)
- [Quick Reference](../../../docs/CILIUM_NETWORK_POLICIES_QUICK_REFERENCE.md)
