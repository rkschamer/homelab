# CiliumNetworkPolicy Quick Reference

## Quick Commands

### View All Policies

```bash
# All CiliumNetworkPolicy resources
kubectl get cnp -A

# All CiliumClusterwideNetworkPolicy resources
kubectl get ccnp

# Detailed view with definitions
kubectl describe cnp -A
kubectl describe ccnp
```

### Monitor Live Traffic

```bash
# Real-time flow monitoring
cilium hubble observe --follow

# Filter by specific pod
cilium hubble observe -l app=traefik --follow

# Show only dropped connections
cilium hubble observe --verdict DROPPED --follow

# Show only allowed connections
cilium hubble observe --verdict ALLOWED --follow
```

### Test Connectivity

```bash
# Exec into pod
kubectl exec -it <pod-name> -- /bin/sh

# Inside pod - test outbound
curl http://8.8.8.8     # Internet access
ping 192.168.123.20     # Control plane access
nc -zv homeassistant.homeassistant.svc 8123  # Service access

# Test inbound (from another pod)
kubectl run test-curl --image=curlimages/curl -it -- \
  curl http://<pod-name>.<namespace>.svc.cluster.local:<port>
```

### Debug Policy Decisions

```bash
# Check pod's network identity
kubectl get cep -n <namespace> <pod-name> -o wide

# List all identities
cilium identity list

# Test policy between two pods
cilium policy trace \
  --src-labels=app=traefik \
  --dst-labels=app=homeassistant

# Get policy statistics
cilium policy get --stats
```

### Common Troubleshooting

```bash
# Check if Cilium is running
kubectl get pods -n kube-system -l k8s-app=cilium

# Check Cilium agent logs
kubectl logs -n kube-system -l k8s-app=cilium

# Get Cilium status
cilium status

# Check policy enforcement mode
kubectl get cm -n kube-system cilium-config -o jsonpath='{.data.enable-policy}'
# Output: 'default' means enforce policies
```

## Common Traffic Patterns

### Allow Pods to Communicate Within Same Network Zone

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-intra-zone
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      network-zone: trusted
  ingress:
  - fromEndpoints:
    - matchLabels:
        network-zone: trusted
```

### Allow Specific Namespace to Reach Service

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-frontend-to-backend
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
  - fromNamespaces:
    - name: frontend
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
```

### Allow External Traffic (Ingress)

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-external-http
spec:
  endpointSelector:
    matchLabels:
      app: webserver
  ingress:
  - toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      - port: "443"
        protocol: TCP
```

### Allow DNS Queries

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-dns-queries
spec:
  endpointSelector:
    matchLabels:
      app: any-app
  egress:
  - toNamespaces:
    - name: kube-system
    toFQDNs:
    - matchName: "*.svc.cluster.local"
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP
```

### Allow Internet Access

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-internet
spec:
  endpointSelector:
    matchLabels:
      app: some-app
  egress:
  - toFQDNs:
    - matchName: "*"  # Any domain
    toPorts:
    - ports:
      - port: "443"
        protocol: TCP
      - port: "80"
        protocol: TCP
```

### Restrict to Specific DNS Names

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-specific-domains
spec:
  endpointSelector:
    matchLabels:
      app: api-client
  egress:
  - toFQDNs:
    - matchName: "api.example.com"
    - matchName: "*.github.com"
    toPorts:
    - ports:
      - port: "443"
        protocol: TCP
```

## Monitoring & Observability

### Hubble UI Dashboard

```bash
# Port forward to Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 8081:80

# Open in browser
# http://localhost:8081
```

### Prometheus Metrics

Cilium exports policy-related metrics:

```
cilium_policy_max_revision
cilium_policy_regeneration_time_stats_seconds
cilium_policy_l7_denied_total
cilium_policy_l7_received_total
```

### Extract Metrics for Analysis

```bash
# Port forward Prometheus
kubectl port-forward -n monitoring svc/prometheus 9090:9090

# Query policy violations
# Metric: cilium_policy_l7_denied_total
# Labels: policy_name, verdict, direction
```

## Policy Deployment Checklist

Before deploying new policies:

- [ ] **Test in dev cluster** - Verify no unintended blocking
- [ ] **Document intent** - Add comments explaining the policy
- [ ] **Label pods correctly** - Ensure pods have required labels
- [ ] **Monitor violations** - Watch Hubble for dropped traffic during rollout
- [ ] **Have rollback plan** - Keep old policies in version control
- [ ] **Validate with Hubble** - Confirm traffic patterns match intent

## Pod Label Requirements

For policies to work, pods must have correct labels:

```yaml
# Network zone label (required for zone-based policies)
labels:
  network-zone: trusted | dmz | untrusted | monitoring

# Application label (recommended for all policies)
labels:
  app: traefik | homeassistant | etc

# Namespace (automatically added)
labels:
  k8s:io.kubernetes.pod.namespace: <namespace>
```

**Add labels to pod manifests**:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  template:
    metadata:
      labels:
        app: myapp
        network-zone: trusted  # Add this
    spec:
      nodeSelector:
        kubernetes.io/hostname: talos-worker-trusted-1
```

## Performance Impact

### Cilium Overhead

- **Egress filtering**: ~2-5% CPU per node
- **Host firewall**: <1% additional CPU
- **DNS tracking**: Minimal (cached)

### Optimization Tips

1. **Use host firewall** for bulk protection (cheaper than pod-level rules)
2. **Aggregate rules** - Group similar pods with same labels
3. **Avoid DNS-based matching** in high-throughput paths
4. **Use `toNamespaces`** instead of individual pod selectors

## Security Best Practices

1. **Always enable default-deny** - Start with deny, explicitly allow
2. **Use least privilege** - Allow only required ports/protocols
3. **Segment by zone** - Different policies per network zone
4. **Monitor violations** - Alert on policy violations
5. **Review quarterly** - Audit policies for obsolete rules
6. **Document changes** - Include intent in policy comments
7. **Test rollback** - Ensure policies can be removed without cluster issues

## When Policies Go Wrong

### All pods denied (even system pods)

**Quick fix**:
```bash
# Temporarily allow all (emergency access)
kubectl patch cep -A --type merge -p '{"spec":{"PolicyEnforcement":"never"}}'

# Then fix the policy issue
```

### Pods can't reach DNS

**Fix**:
```yaml
# Ensure this policy exists
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-dns
spec:
  endpointSelector: {}
  egress:
  - toNamespaces:
    - name: kube-system
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP
```

### Cross-zone communication broken

**Steps**:
1. Check policy exists: `kubectl get cnp <policy-name>`
2. Check pod labels: `kubectl get pods -L network-zone`
3. Check endpoints: `kubectl get cep -A`
4. Monitor flow: `cilium hubble observe --follow`
5. Check verdict: `cilium policy trace --src-labels=<src> --dst-labels=<dst>`
