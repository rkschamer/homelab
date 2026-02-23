# Network Policies - Default-Allow with Zone Isolation

This directory contains CiliumNetworkPolicy resources for zone isolation in the homelab Kubernetes cluster.

## Approach: Default-Allow with Explicit Deny

Instead of a zero-trust default-deny approach (which requires complex allow rules for every legitimate flow), we use **default-allow with explicit deny rules** for critical zone boundaries.

**Why this approach:**
- Simpler to maintain - only deny rules needed
- Network-level segmentation (VLANs) already provides primary isolation
- Appropriate security for a homelab threat model
- No more AUDITED verdicts from missing allow rules

## Network Zones

| Zone | Network | Worker Node | Purpose |
|------|---------|-------------|---------|
| Management | 192.168.123.0/24 | - | Home LAN, Kubernetes API, Proxmox |
| Trusted | 10.10.20.0/24 | talos-worker-trusted-1 | Internal apps with home LAN access |
| DMZ | 10.10.30.0/24 | talos-worker-dmz-1 | Public-facing services (Traefik) |
| Untrusted | 10.10.40.0/24 | talos-worker-untrusted-1 | Experimental workloads, internet-only |
| Monitoring | 10.10.50.0/24 | talos-worker-monitoring-1 | Observability (Prometheus, Grafana, Hubble) |

## Zone Isolation Rules

The `zone-isolation-deny.yaml` file enforces these boundaries:

### Untrusted Zone (Most Restricted)
- ❌ Cannot reach Home LAN (192.168.123.0/24)
- ❌ Cannot reach Trusted zone (10.10.20.0/24)
- ❌ Cannot reach DMZ zone (10.10.30.0/24)
- ❌ Cannot reach Monitoring zone (10.10.50.0/24)
- ✅ Can reach Internet only

### DMZ Zone (Public-Facing)
- ❌ Cannot reach Home LAN (192.168.123.0/24)
- ❌ Cannot reach Untrusted zone (10.10.40.0/24)
- ✅ Can reach Trusted zone (for backend services)
- ✅ Can reach Monitoring zone
- ✅ Can reach Internet

### Monitoring Zone (Observability)
- ✅ Can reach all zones (for metrics scraping)
- ✅ Full cluster access

### Trusted Zone (Internal Services)
- ✅ Full access including Home LAN

## Structure

```
network-policies/
├── zone-isolation-deny.yaml    # All deny rules for zone isolation
├── kustomization.yaml          # Kustomize manifest
└── README.md                   # This file
```

## Labeling Pods for Zone Isolation

Pods must be labeled with `network-zone` to have deny rules applied:

```yaml
apiVersion: v1
kind: Pod
metadata:
  labels:
    network-zone: untrusted  # or: dmz, trusted, monitoring
```

Pods without a `network-zone` label have unrestricted access (default-allow).

## Cilium Configuration

The Cilium HelmRelease uses:
- `policyEnforcementMode: default` - Allow all unless policy selects endpoint
- `policyAuditMode: false` - Deny rules enforce immediately
- `hostFirewall.enabled: true` - Node-level isolation in addition to pod policies

## Testing Zone Isolation

```bash
# Check policies are loaded
kubectl get ccnp

# Verify from an untrusted pod (should be blocked)
kubectl exec -it <untrusted-pod> -- curl -v 192.168.123.1

# Monitor with Hubble
kubectl -n kube-system exec -it ds/cilium -- hubble observe --verdict DROPPED
```

## Adding New Deny Rules

To add a new deny rule, edit `zone-isolation-deny.yaml`:

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: deny-example
spec:
  description: "Description of what this denies"
  endpointSelector:
    matchLabels:
      network-zone: <zone>
  egressDeny:
  - toCIDR:
    - <network-to-block>
```
