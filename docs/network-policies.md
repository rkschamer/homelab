# Network Policies Guide

Comprehensive CiliumNetworkPolicy and host firewall implementation for zero-trust network security across five isolated network zones.

## Architecture

### Security Model

```
┌─────────────────────────────────────────────────────────────┐
│                    Default Deny (Zero Trust)                │
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
           │  DMZ→Trusted ✓  │  DMZ→Untr ✗  │
           │                 │              │
    ┌──────────────────────────────────────────────┐
    │         Monitoring Zone (Pull Metrics)       │
    │  • Prometheus • Grafana • Hubble            │
    └──────────────────────────────────────────────┘
```

### Network Zones

| Zone | Network | Worker Node | Use Case |
|------|---------|-------------|----------|
| Management | 192.168.123.0/24 | talos-controlplane-1 | Kubernetes API, Admin |
| Trusted | 10.10.20.0/24 | talos-worker-trusted-1 | Internal services |
| DMZ | 10.10.30.0/24 | talos-worker-dmz-1 | Public-facing (Traefik) |
| Untrusted | 10.10.40.0/24 | talos-worker-untrusted-1 | Experimental workloads |
| Monitoring | 10.10.50.0/24 | talos-worker-monitoring-1 | Observability |

## ⚠️ Critical: Host Firewall Requirements

When `hostFirewall.enabled: true`, the firewall applies to the **host network namespace**, filtering node-to-node traffic.

### What Breaks Without Base Policies

| Traffic Path | Symptom |
|--------------|---------|
| Worker → API Server (6443) | `kubectl` commands timeout |
| API Server → Kubelet (10250) | `kubectl logs/exec` fail |
| CoreDNS cross-node | DNS resolution fails |
| Cilium VXLAN (8472) | Pod-to-pod cross-node fails |
| Hubble Relay (4244) | Hubble UI shows no flows |

### Required Base Policies

Located in `flux/infrastructure/network-policies/host-firewall-policies.yaml`:

| Policy | Purpose |
|--------|---------|
| `host-allow-apiserver-access` | Workers reach API server |
| `host-allow-kubelet-from-controlplane` | Control plane reaches kubelets |
| `host-allow-cilium-inter-node` | VXLAN 8472, health 4240, Hubble 4244 |
| `host-allow-dns-cross-node` | DNS between nodes |
| `host-allow-talos-api` | `talosctl` access (port 50000) |

### System Pods Scheduling Note

CoreDNS, sealed-secrets, hubble-relay can run on **any node**. Use `fromCIDR/toCIDR` rules to allow traffic from all node networks:

```yaml
- fromCIDR:
  - 10.10.20.0/24   # Trusted
  - 10.10.30.0/24   # DMZ
  - 10.10.40.0/24   # Untrusted
  toPorts:
  - ports:
    - port: "53"
```

## Policy Structure

```
flux/infrastructure/network-policies/
├── clusterwide-policies.yaml       # Default deny, DNS
├── system-policies.yaml            # Flux, Cilium, MetalLB
├── host-firewall-policies.yaml     # Node-to-node rules
├── talos-controlplane-1/           # Control plane host firewall
├── talos-worker-dmz-1/             # Traefik, cross-zone rules
├── talos-worker-trusted-1/         # Internal services
├── talos-worker-untrusted-1/       # Isolated workloads
└── talos-worker-monitoring-1/      # Prometheus, Grafana
```

### Policy Categories

| Category | Policies |
|----------|----------|
| **ClusterWide** | `default-deny-ingress`, `default-allow-dns` |
| **System** | flux-system, kube-system, cilium, metallb, sealed-secrets |
| **DMZ** | traefik ingress, dmz-to-trusted, deny-dmz-to-untrusted |
| **Trusted** | pod-to-pod within zone |
| **Untrusted** | internal only, no cross-zone egress |
| **Monitoring** | cross-zone scrape, grafana access |
| **Host Firewall** | Per-node protection (6443, 10250, 2379) |

## Pod Requirements

### Required Labels

```yaml
metadata:
  labels:
    app: myapp                    # Application identifier
    network-zone: trusted         # Zone: trusted|dmz|untrusted|monitoring
```

### Node Selector

```yaml
spec:
  nodeSelector:
    kubernetes.io/hostname: talos-worker-trusted-1
```

### Complete Example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-api
  namespace: my-app
spec:
  template:
    metadata:
      labels:
        app: my-api
        network-zone: trusted
    spec:
      nodeSelector:
        kubernetes.io/hostname: talos-worker-trusted-1
      containers:
      - name: api
        image: myapi:latest
        ports:
        - containerPort: 8080
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-traefik-to-my-api
  namespace: my-app
spec:
  endpointSelector:
    matchLabels:
      app: my-api
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: traefik
    toPorts:
    - ports:
      - port: "8080"
```

## Quick Commands

### View Policies

```bash
kubectl get cnp -A                    # Namespace policies
kubectl get ccnp                      # Cluster-wide policies
kubectl describe cnp -n <ns> <name>   # Policy details
kubectl get cep -A                    # Cilium endpoints (pods)
```

### Monitor Traffic

All `hubble` commands must be run inside the Cilium pod:

```bash
# Real-time flows
kubectl -n kube-system exec -it ds/cilium -- hubble observe -f

# Dropped connections
kubectl -n kube-system exec -it ds/cilium -- hubble observe --verdict DROPPED -f

# Specific pod
kubectl -n kube-system exec -it ds/cilium -- hubble observe -l app=traefik -f

# Specific port
kubectl -n kube-system exec -it ds/cilium -- hubble observe --to-port 6443

# Audit mode (would-be-blocked traffic)
kubectl -n kube-system exec -it ds/cilium -- hubble observe --verdict AUDIT

# Last N flows
kubectl -n kube-system exec -it ds/cilium -- hubble observe --last 100
```

### Debug Policies

```bash
# Cilium status (from host via cilium-cli)
cilium status

# Detailed agent status (inside Cilium pod)
kubectl -n kube-system exec -it ds/cilium -- cilium-dbg status

# List security identities
kubectl -n kube-system exec -it ds/cilium -- cilium-dbg identity list

# List endpoints with policy status
kubectl -n kube-system exec -it ds/cilium -- cilium-dbg endpoint list

# Monitor policy verdicts in real-time
kubectl -n kube-system exec -it ds/cilium -- cilium-dbg monitor -t policy-verdict

# Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 8081:80
```

## Common Traffic Patterns

### Allow Traefik to Backend

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-traefik-ingress
  namespace: my-app
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: traefik
    toPorts:
    - ports:
      - port: "8080"
```

### Allow Prometheus Scraping

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: my-app
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: prometheus
    toPorts:
    - ports:
      - port: "9100"
```

### Allow Specific External Domains

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-external-api
  namespace: my-app
spec:
  endpointSelector:
    matchLabels:
      app: webhook
  egress:
  - toFQDNs:
    - matchName: "api.github.com"
    toPorts:
    - ports:
      - port: "443"
```

### L7 HTTP Path Filtering

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-api-paths
  namespace: my-app
spec:
  endpointSelector:
    matchLabels:
      app: api
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend
    toPorts:
    - ports:
      - port: "8080"
      rules:
        http:
        - method: "GET"
          path: "/api/v1/.*"
```

## Debugging with Audit Mode

Enable audit mode to test policies without blocking traffic:

```yaml
# In Cilium HelmRelease
policyAuditMode: true
hostFirewall:
  enabled: true
hostFirewallAuditMode: true
```

Check audit logs:

```bash
# Last 100 audit entries
kubectl -n kube-system exec -it ds/cilium -- hubble observe --verdict AUDIT --last 100

# Filter audit by port
kubectl -n kube-system exec -it ds/cilium -- hubble observe --verdict AUDIT --to-port 6443

# Follow audit logs live
kubectl -n kube-system exec -it ds/cilium -- hubble observe --verdict AUDIT -f
```

### Common Missing Policies (from AUDIT logs)

| Pattern | Missing Policy |
|---------|---------------|
| `host -> kube-apiserver:6443` | Workers egress to API server |
| `host -> remote-node:8472 UDP` | VXLAN overlay traffic |
| `host -> remote-node:4240 TCP` | Cilium health checks |
| `coredns -> world:53` | DNS forwarding |

## Troubleshooting

### All Pods Denied

```bash
# Emergency: Temporarily disable enforcement
kubectl patch cep -A --type merge -p '{"spec":{"PolicyEnforcement":"never"}}'

# Fix policies, then re-enable
kubectl patch cep -A --type merge -p '{"spec":{"PolicyEnforcement":"default"}}'
```

### DNS Resolution Failing

Ensure `default-allow-dns` cluster-wide policy exists and CoreDNS can be reached from all nodes.

### Cross-Zone Communication Broken

1. Check policy exists: `kubectl get cnp <name>`
2. Check pod labels: `kubectl get pods -L network-zone`
3. Monitor flow: `kubectl -n kube-system exec -it ds/cilium -- hubble observe -l app=<app> -f`
4. Check endpoint: `kubectl get cep -n <ns> <pod> -o yaml`

### Traefik Can't Reach Backend

Verify `allow-dmz-to-trusted` policy and that backend has correct labels:

```bash
kubectl get cnp allow-dmz-to-trusted -o yaml
kubectl get pods -n <ns> -L app,network-zone
```

## Security Best Practices

1. **Enable host firewall** on production clusters
2. **Use both CNP and host firewall** for defense in depth
3. **Monitor policy violations** via Hubble and Prometheus alerts
4. **Test in audit mode** before enforcing
5. **Document all cross-zone policies** - they represent trust boundaries
6. **Review policies quarterly** for obsolete rules

## Adding New Policies

### For Existing Node

Add to the node's policy file (e.g., `talos-worker-dmz-1/dmz-policies.yaml`)

### For New Worker Node

1. Create folder: `talos-worker-<name>/`
2. Create policy file: `<name>-policies.yaml`
3. Add to `kustomization.yaml`

## References

- [Cilium Network Policy Docs](https://docs.cilium.io/en/latest/security/policy/)
- [Host Firewall](https://docs.cilium.io/en/latest/security/host-firewall/)
- [Hubble Observability](https://docs.cilium.io/en/latest/observability/hubble/)
