# CiliumNetworkPolicy Implementation Summary

## What Has Been Created

This implementation provides comprehensive network security for your homelab using CiliumNetworkPolicy and host firewall rules, aligned with your network topology of five isolated zones.

### 1. **Core Policy Files**

**Location**: `/workspaces/homelab/flux/infrastructure/cilium-network-policies.yaml`

This file contains:

#### ClusterWide Policies (Default Deny)
- `default-deny-ingress` - Zero-trust default denying all ingress
- `default-allow-dns` - Allows DNS queries cluster-wide
- `host-firewall-control-plane` - Protects control plane node from pod-level threats
- `host-firewall-workers` - Protects worker nodes from pod-level threats

#### System Component Policies
- `allow-flux-system-internal` - GitOps core components
- `allow-kube-system-metrics` - Kubernetes core services
- `allow-cilium-internal` - CNI and agent communication
- `allow-hubble-ui` - Network observability dashboard
- `allow-metallb` - Load balancer
- `allow-sealed-secrets` - Secret management

#### Zone-Based Policies
- `allow-traefik-dmz` - Public ingress controller (DMZ worker only)
- `allow-trusted-network-pods` - Internal services
- `allow-untrusted-network-pods` - Experimental/sandboxed workloads
- `allow-monitoring-scrape-all` - Observability with cross-zone access

#### Cross-Zone Communication Rules
- `allow-dmz-to-trusted` - Traefik can reach Trusted backends
- `deny-dmz-to-untrusted` - Strict isolation between DMZ and Untrusted
- `allow-monitoring-cross-zone-scrape` - Prometheus can pull metrics from all zones

### 2. **Documentation**

#### Comprehensive Guide
**Location**: `/workspaces/homelab/docs/CILIUM_NETWORK_POLICIES.md`

Includes:
- Architecture overview
- Policy categories and how they work
- Host firewall deep dive
- Testing procedures
- Debugging guide with Hubble
- Extension examples
- Security best practices
- Troubleshooting common issues

#### Quick Reference
**Location**: `/workspaces/homelab/docs/CILIUM_NETWORK_POLICIES_QUICK_REFERENCE.md`

Includes:
- Quick commands for viewing and monitoring policies
- Common traffic patterns (copy-paste templates)
- Troubleshooting quick fixes
- Pod label requirements
- Performance impact information
- Emergency procedures

### 3. **Validation Script**

**Location**: `/workspaces/homelab/scripts/validate-cilium-policies.sh`

Checks:
- Cilium installation
- Policy resource counts
- Enforcement configuration
- Host firewall status
- Pod network zone labels
- Hubble status
- Agent health
- Policy statistics

---

## Network Architecture Implemented

```
┌─────────────────────────────────────────────────────────────┐
│                    Default Deny (Zone Trust)                │
│  All ingress denied unless explicitly allowed               │
└─────────────────────────────────────────────────────────────┘
              │              │              │
    ┌─────────▼──────┐ ┌────▼──────┐ ┌────▼──────┐
    │ Trusted Zone   │ │ DMZ Zone  │ │ Untrusted │
    │ (10.10.20.0)   │ │(10.10.30) │ │(10.10.40) │
    │                │ │           │ │           │
    │ • Home Asst    │ │• Traefik  │ │• Dev Apps │
    │ • NAS          │ │• Ingress  │ │• Testing  │
    │ • Databases    │ │           │ │           │
    └────────────────┘ └────┬──────┘ └───────────┘
           │                 │              │
           │  Can reach      │              │
           │  from Traefik   │  Isolated    │
           │                 │              │
    ┌──────────────────────────────────────────────┐
    │         Monitoring Zone (Pull Metrics)       │
    │  • Prometheus • Grafana • Hubble            │
    └──────────────────────────────────────────────┘
           ▲              ▲              ▲
           └──────────────┴──────────────┘
           One-way metrics collection
```

---

## How It Works

### 1. **Default Deny Foundation**
```yaml
CiliumClusterwideNetworkPolicy "default-deny-ingress"
# Result: All pods start in deny state
```

### 2. **Explicit Allow Rules**
- System components (Flux, Cilium, MetalLB) can communicate
- DNS queries allowed cluster-wide
- Traefik can receive external traffic
- Traefik can reach Trusted backends
- Monitoring can pull metrics from all zones

### 3. **Zone Isolation**
- Trusted pods only talk to Trusted pods
- Untrusted pods completely isolated
- DMZ (Traefik) explicitly allowed to Trusted but not Untrusted
- Control plane protected by host firewall

### 4. **Host Firewall Protection**
- Node-level filtering prevents pod escapes
- Even if container breaks cgroup, can't access host services
- Kubernetes API (6443) protected
- Kubelet API (10250) protected
- etcd (2379) protected

---

## Deployment Instructions

### 1. **Update Kustomization** (Already Done)
The `kustomization.yaml` in `flux/infrastructure/` now includes the new policies:
```yaml
resources:
  - cilium-config.yaml
  - cilium-network-policies.yaml
```

### 2. **Deploy via Flux**
If Flux is watching the repository:
```bash
cd /workspaces/homelab
git add .
git commit -m "Add CiliumNetworkPolicy and host firewall rules"
git push

# Flux will automatically apply the policies
# Monitor progress:
flux get kustomization infrastructure --watch
```

### 3. **Manual Deployment (if not using Flux)**
```bash
kubectl apply -f flux/infrastructure/cilium-network-policies.yaml
```

### 4. **Verify Deployment**
```bash
# Check policies are created
kubectl get cnp -A
kubectl get ccnp

# Run validation script
./scripts/validate-cilium-policies.sh

# Monitor live traffic
cilium hubble observe --follow
```

---

## Important Configuration Steps

### 1. **Label Your Pods**
For zone-based policies to work, pods must have the network zone label:

```yaml
spec:
  template:
    metadata:
      labels:
        network-zone: trusted  # or dmz, untrusted, monitoring
        app: my-app
```

### 2. **Enable Host Firewall**
This is optional but recommended. To enable:

```bash
kubectl set env daemonset/cilium -n kube-system CILIUM_HOST_FIREWALL=true
```

Or in Cilium HelmRelease values:
```yaml
hostFirewall:
  enabled: true
```

### 3. **Configure Node Selectors**
Ensure pods are scheduled on correct workers:

```yaml
nodeSelector:
  kubernetes.io/hostname: talos-worker-dmz-1  # For DMZ apps
  kubernetes.io/hostname: talos-worker-trusted-1  # For Trusted apps
```

---

## Testing the Policies

### Quick Test: Verify Default Deny

```bash
# Deploy a test pod
kubectl run test-pod --image=alpine --rm -it -- /bin/sh

# Inside the pod, try to listen on port 8080
nc -l -p 8080

# From another pod (in different terminal):
kubectl run test-client --image=alpine --rm -it -- /bin/sh
# Try to connect (should timeout - ingress denied)
nc -zv test-pod.default 8080
# Should fail!
```

### Test: Traefik to Trusted Backend

```bash
# Verify policy allows DMZ to Trusted
kubectl exec -it deployment/traefik -n kube-system -- /bin/sh

# Inside Traefik:
curl http://homeassistant.homeassistant.svc.cluster.local:8123
# Should succeed!

curl http://untrusted-app.default.svc.cluster.local
# Should fail!
```

### Monitor with Hubble

```bash
# Watch all traffic in real-time
cilium hubble observe --follow

# Filter by specific policy
cilium hubble observe --verdict DROPPED --follow

# View a specific service
cilium hubble observe -l app=traefik --follow
```

---

## Key Features Included

✅ **Zero Trust**: Default deny all, explicitly allow required traffic
✅ **Host Firewall**: Protect nodes from pod-level escapes
✅ **Zone Isolation**: Physical network zones enforced at pod level
✅ **Cross-Zone Rules**: Explicit allow rules for necessary communication
✅ **Monitoring**: One-way pull for observability
✅ **DNS**: Cluster-wide DNS resolution allowed
✅ **System Components**: Flux, Cilium, MetalLB can function
✅ **Hubble Integration**: Built-in observability and debugging

---

## Next Steps

### 1. **Deploy and Test** (If not using Flux)
```bash
kubectl apply -f flux/infrastructure/cilium-network-policies.yaml
./scripts/validate-cilium-policies.sh
cilium hubble observe --follow
```

### 2. **Label Existing Pods**
Add network zone labels to running pods and redeployments

### 3. **Create Application-Specific Policies**
For each app, add ingress rules in the app's namespace:
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-app-ingress
  namespace: my-app
spec:
  endpointSelector:
    matchLabels:
      app: my-app
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: traefik
```

### 4. **Monitor Policy Violations**
Set up Prometheus alerts on policy drop metrics:
```
cilium_policy_l7_denied_total > 0
```

### 5. **Document Custom Policies**
Any app-specific policies should be committed to Git with comments

---

## Files Created/Modified

| File | Purpose |
|------|---------|
| `/workspaces/homelab/flux/infrastructure/cilium-network-policies.yaml` | All CiliumNetworkPolicy and CiliumClusterwideNetworkPolicy resources |
| `/workspaces/homelab/flux/infrastructure/kustomization.yaml` | Updated to include policies |
| `/workspaces/homelab/docs/CILIUM_NETWORK_POLICIES.md` | Comprehensive guide |
| `/workspaces/homelab/docs/CILIUM_NETWORK_POLICIES_QUICK_REFERENCE.md` | Quick reference |
| `/workspaces/homelab/scripts/validate-cilium-policies.sh` | Validation script |

---

## References

- [Cilium Network Policy Docs](https://docs.cilium.io/en/latest/security/policy/)
- [Cilium Host Firewall](https://docs.cilium.io/en/latest/security/host-firewall/)
- [Hubble Observability](https://docs.cilium.io/en/latest/observability/hubble/)
- [CiliumClusterwideNetworkPolicy API](https://docs.cilium.io/en/latest/reference/k8s-api/cilium-clusterwide-network-policy/)

---

## Summary

You now have production-ready network policies that:
- Enforce zero-trust security at pod and host level
- Maintain isolation between network zones
- Allow necessary cross-zone communication
- Provide complete observability via Hubble
- Protect critical infrastructure from pod-level threats

All policies are version-controlled in Git and can be deployed via Flux CD as part of your GitOps infrastructure.
