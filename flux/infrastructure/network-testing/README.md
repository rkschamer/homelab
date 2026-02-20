# Network Testing Pods

This directory contains Flux manifests for deploying network testing pods on all cluster nodes for validating Cilium network policies.

## Pods Deployed

### `network-policy-test` DaemonSet

- **Purpose:** Testing Cilium network policy enforcement
- Uses standard pod networking — **subject to all CiliumNetworkPolicies**
- Non-privileged — runs like a normal application pod
- Deployed on all nodes including control plane
- Image: `nicolaka/netshoot` (includes curl, dig, ping, netcat, etc.)

## Usage

```bash
# List all pods with their node placement
kubectl get pods -n network-testing -o wide

# Test connectivity from a specific node
kubectl exec -it network-policy-test-xxxxx -n network-testing -- ping 192.168.123.5
kubectl exec -it network-policy-test-xxxxx -n network-testing -- curl http://some-service
kubectl exec -it network-policy-test-xxxxx -n network-testing -- dig kubernetes.default
kubectl exec -it network-policy-test-xxxxx -n network-testing -- nc -zv some-host 80
```

## Testing Network Isolation

Verify policy enforcement across network segments:

```bash
# Find pods by node
kubectl get pods -n network-testing -o wide

# From untrusted worker - should be BLOCKED from reaching home LAN
kubectl exec -it <pod-on-untrusted> -n network-testing -- ping 192.168.123.5

# From trusted worker - should be ALLOWED to reach home LAN
kubectl exec -it <pod-on-trusted> -n network-testing -- ping 192.168.123.5
```

## Testing Network Policies

Use these pods to verify policy enforcement across your network segments:

- **From DMZ worker:** Test connectivity to trusted and untrusted networks
- **From Trusted worker:** Verify home LAN access and isolation from untrusted
- **From Untrusted worker:** Confirm isolation from trusted and monitoring networks
- **From Monitoring worker:** Test observability network policies
- **On Control Plane:** Verify control plane network isolation

## Cleanup

To remove these pods, delete the namespace:

```bash
kubectl delete namespace network-testing
```

Or let Flux handle reconciliation by removing the reference from the infrastructure Kustomization.
