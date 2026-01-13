# Cilium and Hubble Installation Guide

This guide provides detailed instructions for installing Cilium as the CNI and Hubble for network observability on your Talos Kubernetes cluster.

## Overview

**Cilium** replaces kube-proxy and provides:
- Efficient packet processing via eBPF (extended Berkeley Packet Filter)
- Network policies (CiliumNetworkPolicy) for pod-to-pod security
- Service load balancing
- DNS visibility
- Encryption (optional WireGuard)

**Hubble** provides:
- Network flow visualization
- Protocol-level insights (DNS, HTTP, gRPC)
- Network policy debugging
- Security event logging

## Prerequisites

Ensure the following tools are installed on your local machine:

```bash
# Install/verify helm
helm version

# Install/verify kubectl
kubectl version --client

# (Optional) Install cilium-cli for advanced diagnostics
curl -L https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz | sudo tar xz -C /usr/local/bin
cilium version
```

Verify cluster access:

```bash
# Export talosconfig from your Terraform output
export TALOSCONFIG=$PWD/proxmox/terraform/talos/gen/talosconfig

# Generate kubeconfig
talosctl kubeconfig . --nodes 192.168.123.20

# Verify cluster access
kubectl get nodes
# Output should show control plane and worker nodes in Ready state
```

## Installation Steps

### Step 1: Add Cilium Helm Repository

```bash
helm repo add cilium https://helm.cilium.io
helm repo update
```

### Step 2: Create Cilium Namespace

```bash
kubectl create namespace cilium
```

### Step 3: Install Cilium with Hubble

Install Cilium with the following configuration optimized for your environment:

```bash
helm install cilium cilium/cilium \
  --namespace cilium \
  --set kubeProxyReplacement=true \
  --set ebpf.enabled=true \
  --set hubble.enabled=true \
  --set hubble.metrics.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set l7Proxy=true \
  --set policyEnforcementMode=default \
  --set routingMode=native \
  --set endpointRoutes.enabled=true \
  --set ipam.mode=kubernetes \
  --wait
```

**Configuration Explanation:**

| Option | Value | Purpose |
|--------|-------|---------|
| `kubeProxyReplacement` | `true` | Cilium replaces kube-proxy for service load balancing |
| `ebpf.enabled` | `true` | Use eBPF for efficient networking and packet processing |
| `hubble.enabled` | `true` | Enable Hubble for network observability |
| `hubble.metrics.enabled` | `true` | Collect Prometheus metrics from Hubble |
| `hubble.relay.enabled` | `true` | Enable Hubble relay for centralized observability |
| `hubble.ui.enabled` | `true` | Deploy Hubble UI dashboard (optional, requires port-forward) |
| `l7Proxy` | `true` | Enable Layer 7 (application-level) visibility and policy |
| `policyEnforcementMode` | `default` | Enforce policies (default = deny unless explicitly allowed) |
| `routingMode` | `native` | Use native routing (assumes Proxmox host routes between bridges) |
| `endpointRoutes.enabled` | `true` | Use per-endpoint routes for better efficiency |
| `ipam.mode` | `kubernetes` | Use Kubernetes for IPAM (IP address management) |

### Step 4: Verify Installation

**Check Cilium Pods:**

```bash
kubectl get pods -n cilium
# Output should show:
# cilium-*                    RUNNING
# cilium-operator-*           RUNNING
# hubble-relay-*              RUNNING
# hubble-ui-*                 RUNNING (if enabled)
```

**Check Cilium Agent Status:**

```bash
# SSH into a node or use kubectl debug
kubectl exec -n cilium -t ds/cilium -- cilium status

# Output should show:
# Cilium:        OK
# Operator:      OK
# Hubble Relay:  OK
# Hubble UI:     OK
# Connectivity:  OK
```

**Verify kube-proxy is Disabled:**

```bash
kubectl get daemonset -n kube-system kube-proxy
# Should return "No resources found" or show 0 running pods
```

**Check Node Status:**

```bash
kubectl get nodes
# All nodes should show Ready status once Cilium is fully deployed
```

### Step 5: Access Hubble UI (Optional)

Hubble UI provides a visual network map and flow debugging interface.

**Port-forward to Hubble UI:**

```bash
kubectl port-forward -n cilium svc/hubble-ui 8081:80
```

Then visit in your browser:
```
http://localhost:8081
```

**Features in Hubble UI:**
- Network topology map showing pod-to-pod communication
- Flow logs with protocol details (DNS, HTTP, gRPC)
- Policy evaluation visualization
- Service dependencies

### Step 6: Verify Connectivity

Test basic cluster networking:

```bash
# Deploy a test pod
kubectl create deployment nginx --image=nginx --replicas=2

# Verify pods are running
kubectl get pods

# Test connectivity between pods
POD1=$(kubectl get pods -o name | head -1 | cut -d/ -f2)
POD2=$(kubectl get pods -o name | tail -1 | cut -d/ -f2)

kubectl exec $POD1 -- curl http://$POD2.default.svc.cluster.local:80

# Clean up
kubectl delete deployment nginx
```

## Network Policies with Cilium

Once Cilium is running, you can define security policies using CiliumNetworkPolicy resources.

### Example: Default Deny + Allow Traffic

Create a file `network-policy.yaml`:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  description: "Default deny all traffic unless explicitly allowed"
  endpointSelector: {}
  ingress: []
  egress:
    # Allow DNS to any endpoint
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: UDP
          port: "53"
    # Allow traffic to other cluster IPs (Kubernetes API, etc.)
    - to:
        - namespaceSelector: {}
```

Apply it:

```bash
kubectl apply -f network-policy.yaml
```

## Troubleshooting

### Cilium pods not starting

```bash
# Check pod logs
kubectl logs -n cilium -l k8s-app=cilium --tail=100

# Common issues:
# - Not enough resources: Check node memory/CPU
# - eBPF not available: Check kernel version (5.8+), run: uname -r
```

### Connectivity issues

```bash
# Check Cilium agent logs on a specific node
kubectl exec -n cilium -t ds/cilium -l node.kubernetes.io/instance-type=worker-1 -- cilium status --verbose

# Use cilium-cli for advanced diagnostics
cilium connectivity test
```

### Hubble metrics not working

```bash
# Check Hubble relay
kubectl logs -n cilium -l k8s-app=hubble-relay

# Verify metrics endpoint
kubectl port-forward -n cilium svc/hubble-metrics 9091:9091
curl localhost:9091/metrics
```

## Cilium with Network Isolation

For your specific architecture with isolated worker networks (vmbr1-4), Cilium provides pod-level policies while the underlying Linux bridges provide network segmentation:

**Pod-level isolation example** (DMZ namespace):

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: dmz-ingress-only
  namespace: dmz
spec:
  description: "DMZ pods can only receive traffic, not initiate to trusted network"
  endpointSelector:
    matchLabels:
      zone: dmz
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: dmz
  egress:
    # Allow DNS
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: UDP
          port: "53"
    # Allow traffic to external/management network (Traefik backends)
    - to:
        - cidrSet:
            - 192.168.123.0/24  # Management network
      ports:
        - protocol: TCP
          port: "80"
        - protocol: TCP
          port: "443"
```

## References

- [Cilium Documentation](https://docs.cilium.io/)
- [Hubble Documentation](https://docs.cilium.io/en/stable/observability/hubble/)
- [CiliumNetworkPolicy Documentation](https://docs.cilium.io/en/stable/security/policy/)
- [Cilium on Talos](https://docs.cilium.io/en/stable/installation/talos/)
- [Talos Kubernetes Documentation](https://www.talos.dev/latest/)
