# Network Policies - Pod-Level Zone Isolation

This directory contains CiliumNetworkPolicy resources for zone isolation in the homelab Kubernetes cluster.

## Approach: Namespace-Based Pod-Level Isolation

All worker nodes (2 nodes) share the same physical network (10.10.20.0/24). **Network zones are now enforced at the pod level** using:
1. **Namespace labels:** `network-zone: [trusted|dmz|untrusted|monitoring]`
2. **Cilium Network Policies:** Rules match on namespace labels to enforce isolation

**Why this approach:**
- Reduced infrastructure overhead: 2 VMs instead of 4
- Pod scheduling is fully flexible - any pod can run on any worker
- Industry-standard Kubernetes pattern (namespace + NetworkPolicy)
- Cilium policies provide deep packet inspection and zero-trust enforcement
- Easy to scale: add more workers without network reconfiguration
- Better for high availability and rolling updates

## Network Zones (Logical, Pod-Level)

| Zone | Namespace Label | Purpose | Pod Connectivity |
|------|-----------------|---------|----------------------|
| **Trusted** | `network-zone: trusted` | Internal services (Home Assistant, NAS, databases) with home LAN access | Can reach: Home LAN, Management, Internet |
| **DMZ** | `network-zone: dmz` | Public-facing services (Traefik Ingress). Isolated from home LAN | Can reach: Internet, explicit Trusted backends; Blocked: Home LAN |
| **Untrusted** | `network-zone: untrusted` | Experimental workloads, development, testing, sandboxing | Can reach: Internet only; Blocked: Home LAN, Trusted, DMZ, Monitoring |
| **Monitoring** | `network-zone: monitoring` | Observability infrastructure (Prometheus, Grafana, Hubble) | Can reach: All zones (pull-only); Others cannot push to Monitoring |

## Zone Isolation Rules

The `zone-isolation-deny.yaml` file enforces these boundaries using Cilium Network Policies with namespace selectors:

### Untrusted Zone (Most Restricted)
- ❌ Cannot reach Home LAN (192.168.123.0/24)
- ❌ Cannot reach Trusted zone pods
- ❌ Cannot reach DMZ zone pods
- ❌ Cannot reach Monitoring zone pods
- ✅ Can reach Internet only

### DMZ Zone (Public-Facing)
- ❌ Cannot reach Home LAN (192.168.123.0/24) - **CRITICAL: Protects private network**
- ❌ Cannot reach Untrusted zone pods
- ✅ Can reach Trusted zone pods (for backend services, via explicit policies)
- ✅ Can reach Monitoring zone pods
- ✅ Can reach Internet

### Monitoring Zone (Observability)
- ✅ Can reach all zones (for metrics scraping)
- ✅ Full cluster access

### Trusted Zone (Internal Services)
- ✅ Full access including Home LAN

## How to Use

### 1. Label Namespaces

Apply the `namespace-zone-labels.yaml` to create labeled namespaces, or label existing ones:

```bash
# Create labeled namespaces
kubectl apply -f namespace-zone-labels.yaml

# Or label existing namespaces
kubectl label namespace traefik network-zone=dmz
kubectl label namespace homeassistant network-zone=trusted
kubectl label namespace experimental network-zone=untrusted
kubectl label namespace monitoring network-zone=monitoring
```

### 2. Deploy Pods to Labeled Namespaces

No `nodeSelector` needed! Deploy pods normally; Cilium enforces isolation:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traefik
  namespace: traefik  # Already labeled network-zone=dmz
spec:
  template:
    spec:
      containers:
      - name: traefik
        image: traefik:v2.x
      # Cilium automatically enforces DMZ zone policies
      # Pod can run on any worker; isolation still enforced
```

### 3. Allow Cross-Zone Traffic (Optional)

For legitimate cross-zone communication (e.g., Traefik → backend services), create specific allow policies:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-dmz-to-homeassistant
  namespace: homeassistant
spec:
  endpointSelector:
    matchLabels:
      app: homeassistant
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          network-zone: dmz
    ports:
    - protocol: TCP
      port: "8123"
```

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
