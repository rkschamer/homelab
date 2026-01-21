# CiliumNetworkPolicy Implementation Guide

This guide explains the comprehensive CiliumNetworkPolicy setup for the homelab, including host firewall rules and zone-based network isolation.

## Overview

The network policy architecture implements **zero-trust security** with the following principles:

1. **Default Deny**: All ingress traffic denied by default unless explicitly allowed
2. **Zone Isolation**: Network zones (Trusted, DMZ, Untrusted, Monitoring) remain isolated
3. **Explicit Allowlisting**: Only necessary cross-zone communication is permitted
4. **Host Firewall Protection**: Host networking protected from pod-level threats
5. **Observability**: Monitoring zone can observe all zones (one-way pull)

## Architecture

### Network Zones

| Zone | Network | Use Case | Pod Label |
|------|---------|----------|-----------|
| Management | 192.168.123.0/24 | Kubernetes API, Admin access | `network-zone: management` |
| Trusted | 10.10.20.0/24 | Internal services (Home Assistant, NAS) | `network-zone: trusted` |
| DMZ | 10.10.30.0/24 | Public-facing services (Traefik) | `network-zone: dmz` |
| Untrusted | 10.10.40.0/24 | Experimental workloads (sandboxed) | `network-zone: untrusted` |
| Monitoring | 10.10.50.0/24 | Observability infrastructure | `network-zone: monitoring` |

### Key Policies

#### 1. Default Deny ClusterWide Policy

```yaml
CiliumClusterwideNetworkPolicy:
  - name: default-deny-ingress
    ingress: []  # No ingress allowed by default
```

**Purpose**: Establishes zero-trust default. All pods must be explicitly allowed.

**Implications**:
- All pods start in "deny all ingress" state
- Specific policies must allow needed traffic
- Reduces blast radius of compromised pods

#### 2. Host Firewall Protection

```yaml
CiliumClusterwideNetworkPolicy:
  - name: host-firewall-control-plane
    nodeSelector:
      kubernetes.io/hostname: talos-controlplane-1
```

**Purpose**: Protects the host OS from pod-level escapes or rogue container behavior.

**Protected Ports**:
- `6443` - Kubernetes API
- `10250` - Kubelet API
- `2379` - etcd (if running on host)

**Benefits**:
- Even if a pod breaks out of its cgroup, it cannot modify host routing
- DNS hijacking from containers is limited to pod namespace
- System services remain protected

#### 3. Zone-Based Pod Isolation

**Trusted Network**:
```yaml
CiliumNetworkPolicy:
  - name: allow-trusted-network-pods
    nodeSelector:
      kubernetes.io/hostname: talos-worker-trusted-1
    endpointSelector:
      matchLabels:
        network-zone: trusted
    ingress:
      - fromEndpoints:
        - matchLabels:
            network-zone: trusted
      - fromEndpoints:  # Traefik ingress
        - app: traefik
```

**DMZ Network** (Public-Facing):
```yaml
CiliumNetworkPolicy:
  - name: allow-traefik-dmz
    endpointSelector:
      matchLabels:
        app: traefik
    ingress:
      - toPorts:  # Accept external traffic on 80/443
        - ports:
          - port: "80"
          - port: "443"
    egress:
      - toEndpoints:  # Can only reach Trusted backends
        - matchLabels:
            network-zone: trusted
```

**Untrusted Network** (Sandboxed):
```yaml
CiliumNetworkPolicy:
  - name: allow-untrusted-network-pods
    nodeSelector:
      kubernetes.io/hostname: talos-worker-untrusted-1
    endpointSelector:
      matchLabels:
        network-zone: untrusted
    ingress:
      - fromEndpoints:  # Only pod-to-pod on same network
        - matchLabels:
            network-zone: untrusted
    # No egress to Trusted or DMZ
```

## Policy Categories

### System Component Policies

These allow core Kubernetes components to function:

1. **DNS Resolution**: All pods can query coredns
2. **Flux System**: GitOps controller components communicate
3. **Kube System**: Core components (apiserver, kubelet, etc.)
4. **Cilium**: CNI agent and Hubble observability
5. **MetalLB**: Load balancer speaker and controller
6. **Sealed Secrets**: Secret decryption controller

### Application Policies

1. **Traefik Ingress**: Receives external traffic, routes to backends
2. **Trusted Workloads**: Internal services with home LAN access
3. **Untrusted Workloads**: Experimental pods with strict isolation
4. **Monitoring Stack**: Prometheus scraping metrics from all zones

### Cross-Zone Policies

1. **DMZ → Trusted**: Traefik can forward to Home Assistant, NAS
2. **DMZ ↔ Untrusted**: Denied (strict isolation)
3. **Monitoring ↔ All**: One-way pull for metrics collection
4. **All → Management**: Only through explicit cluster communication

## Applying the Policies

The policies are deployed via Flux CD:

```bash
# Check if policies are deployed
kubectl get cnp -A
kubectl get ccnp

# Watch policy enforcement
cilium policy get

# View policy verdicts (Hubble)
cilium hubble observe --follow

# Check specific pod's allowed traffic
cilium policy get -o json | jq '.[] | select(.Labels[0] | contains("app=traefik"))'
```

## Testing Policies

### Test Default Deny

```bash
# Deploy a test pod
kubectl run test-pod --image=alpine -it -- /bin/sh

# Inside the pod:
ping 8.8.8.8            # Should work (egress allowed)
nc -l -p 8080           # Listen for incoming connections

# From another pod:
telnet test-pod 8080    # Should timeout (ingress denied)
exit
```

### Test Zone Isolation

```bash
# Deploy on Trusted zone
kubectl run trusted-pod --image=alpine -it \
  --overrides='{"spec":{"nodeSelector":{"network-zone":"trusted"}}}'

# Deploy on Untrusted zone
kubectl run untrusted-pod --image=alpine -it \
  --overrides='{"spec":{"nodeSelector":{"network-zone":"untrusted"}}}'

# Try communication (should fail)
ping untrusted-pod  # Should timeout
```

### Test Traefik to Trusted Communication

```bash
# Verify Traefik can reach Trusted backends
kubectl exec -it deployment/traefik -n kube-system -- /bin/sh

# Inside Traefik:
curl http://homeassistant.homeassistant.svc.cluster.local:8123
# Should succeed (policy allows it)

curl http://untrusted-app.default.svc.cluster.local
# Should fail (policy denies it)
exit
```

### Monitor Violations

```bash
# View dropped packets in real-time
cilium hubble observe --follow --verdict DROPPED

# Specific policy violations
cilium policy get --stats

# Export metrics to Prometheus
# Already configured in prometheus deployment
```

## Debugging Policies

### Check Pod's Network Identity

```bash
kubectl get cep -A -o wide
# Shows each pod's Cilium endpoint identity
```

### Simulate Policy Decision

```bash
# Check what traffic is allowed from pod A to pod B
cilium identity list
# Use output to check policy rules

# Detailed policy trace
cilium policy trace --src-labels=app=traefik --dst-labels=app=homeassistant
```

### Hubble CLI

```bash
# Real-time flow monitoring
cilium hubble observe --follow

# Specific namespace
cilium hubble observe -n kube-system --follow

# Specific pod
cilium hubble observe -l app=traefik --follow

# Filter by policy verdict
cilium hubble observe --verdict ALLOWED
cilium hubble observe --verdict DROPPED
```

### Hubble UI

```bash
# Access Hubble UI dashboard
kubectl port-forward -n kube-system svc/hubble-ui 8081:80

# Open in browser
open http://localhost:8081
```

## Host Firewall Deep Dive

Host firewall protects the Talos node OS itself:

```yaml
CiliumClusterwideNetworkPolicy:
  spec:
    nodeSelector:
      kubernetes.io/hostname: talos-controlplane-1
    ingress:
      - fromEndpoints: {}  # From any pod
        toPorts:
          - ports:
            - port: "6443"   # Kubernetes API
            - port: "10250"  # Kubelet
```

### How It Works

1. **Pod → Host**: Traffic from pod to node IP on protected port is filtered
2. **Host → Pod**: Return traffic is allowed (established connections)
3. **Host → External**: Host can always initiate (no ingress needed)
4. **Pod Escape**: Even if pod breaks cgroup, it can't access protected host services

### Protected Services

| Port | Service | Protection |
|------|---------|-----------|
| 6443 | Kubernetes API | Can't be spoofed or hijacked |
| 10250 | Kubelet API | Can't patch kubelet config |
| 2379 | etcd | Can't manipulate cluster state |
| 22 | SSH | Can't access host shell (if enabled) |

## Security Considerations

### Assumptions

- Talos runs in immutable mode (root filesystem read-only)
- No privilege containers by default
- Network stack protected by Linux hardening

### Limitations

- Host firewall doesn't protect between containers on same host
- Use `securityContext` to enforce Pod Security Standards
- NetworkPolicy and host firewall are complementary, not redundant

### Best Practices

1. **Always enable host firewall** on production clusters
2. **Use both CNP and host firewall** for defense in depth
3. **Monitor policy violations** via Hubble metrics
4. **Test policies in dev** before applying to production
5. **Document all cross-zone policies** - they represent trust boundaries

## Extending the Policies

### Add New Zone

1. Create worker node with new network segment
2. Label pods: `network-zone: myzone`
3. Create CiliumNetworkPolicy for the zone:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-myzone-pods
  namespace: default
spec:
  nodeSelector:
    kubernetes.io/hostname: talos-worker-myzone-1
  endpointSelector:
    matchLabels:
      network-zone: myzone
  ingress:
  - fromEndpoints:
    - matchLabels:
        network-zone: myzone
  egress:
  - toEndpoints:
    - matchLabels:
        network-zone: myzone
```

### Add L7 Rules (Application Layer)

Example: Allow only specific HTTP paths:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-api-endpoints
spec:
  endpointSelector:
    matchLabels:
      app: api-server
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: "GET"
          path: "/api/v1/.*"
        - method: "POST"
          path: "/api/v1/data"
```

### Add DNS-Based Rules

Example: Allow only specific DNS names:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-external-api
spec:
  endpointSelector:
    matchLabels:
      app: webhook
  egress:
  - toFQDNs:
    - matchName: "github.com"
    - matchName: "*.githubusercontent.com"
    toPorts:
    - ports:
      - port: "443"
        protocol: TCP
```

## Troubleshooting Common Issues

### Problem: All pods denied by default

**Symptom**: Even system pods can't communicate

**Cause**: `default-deny-ingress` policy too strict

**Solution**: Ensure system namespaces have explicit allow rules:

```yaml
CiliumNetworkPolicy:
  namespaceSelector:
    matchLabels:
      name: kube-system
  ingress:
  - fromEndpoints: {}  # Allow all in namespace
```

### Problem: Cross-zone communication failing

**Symptom**: Traefik can't reach Trusted backends

**Cause**: Missing explicit egress policy

**Solution**: Check `allow-dmz-to-trusted` policy exists and matches pod labels

```bash
kubectl get cnp allow-dmz-to-trusted -o yaml
# Verify toEndpoints has correct labels
```

### Problem: Monitoring can't scrape metrics

**Symptom**: Prometheus scrape targets failing

**Cause**: No ingress rule for monitoring namespace

**Solution**: Add ingress rule in each workload namespace:

```yaml
ingress:
- fromNamespaces:
  - name: monitoring
  fromLabelSelector:
    matchLabels:
      app: prometheus
  toPorts:
  - ports:
    - port: "9100"
```

## References

- [Cilium Network Policy Documentation](https://docs.cilium.io/en/latest/security/policy/)
- [CiliumNetworkPolicy CRD](https://docs.cilium.io/en/latest/reference/k8s-api/cilium-network-policy/)
- [CiliumClusterwideNetworkPolicy](https://docs.cilium.io/en/latest/reference/k8s-api/cilium-clusterwide-network-policy/)
- [Host Firewall](https://docs.cilium.io/en/latest/security/host-firewall/)
- [Hubble Observability](https://docs.cilium.io/en/latest/observability/hubble/)
- [Cilium Best Practices](https://docs.cilium.io/en/latest/security/policy/guidance/)
