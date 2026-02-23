# Network Testing Pods

This directory contains Flux manifests for deploying network testing pods for validating Cilium network policies and host firewall rules.

## Pods Deployed

### `network-policy-test` DaemonSet

- **Purpose:** Testing Cilium pod network policies (default network namespace)
- Uses standard pod networking — **subject to all CiliumNetworkPolicies**
- Non-privileged — runs like a normal application pod
- Deployed on all nodes including control plane
- Image: `nicolaka/netshoot` (includes curl, dig, ping, netcat, etc.)

### `host-firewall-test-{untrusted,dmz,trusted}` DaemonSets

- **Purpose:** Testing Cilium host firewall rules (host network policies)
- Runs with `hostNetwork: true` — **subject to host firewall rules**
- Privileged for network testing with elevated capabilities
- Deployed one per zone worker node (untrusted, DMZ, trusted)
- Image: `nicolaka/netshoot`

**Important:** Cilium host firewall rules **only apply to `hostNetwork: true` pods**. Regular pods in the pod network are not subject to `nodeSelector`-based `egressDeny`/`ingressDeny` rules. Use these host network test pods to verify host firewall enforcement.

## Usage

### Test Container Access

```bash
# Find all test pods by zone
kubectl get pods -n network-testing -o wide -l app=host-firewall-test

# Find pods by specific zone
kubectl get pods -n network-testing -o wide -l zone=untrusted
kubectl get pods -n network-testing -o wide -l zone=dmz
kubectl get pods -n network-testing -o wide -l zone=trusted
```

### Run Network Tests

```bash
# Execute commands inside a test pod
kubectl exec -it <pod-name> -n network-testing -- ping 192.168.123.5
kubectl exec -it <pod-name> -n network-testing -- curl -v http://192.168.123.1
kubectl exec -it <pod-name> -n network-testing -- traceroute 10.10.20.5
kubectl exec -it <pod-name> -n network-testing -- nc -zv 192.168.123.5 443

# Interactive shell
kubectl exec -it <pod-name> -n network-testing -- bash
```

## Testing Host Firewall Rules

Verify zone isolation using the host network test pods:

### Untrusted Zone (should be DENIED)

```bash
# Get untrusted zone test pod
POD=$(kubectl get pod -n network-testing -l zone=untrusted -o jsonpath='{.items[0].metadata.name}')

# Should be DENIED by deny-untrusted-to-internal rule
kubectl exec -it $POD -n network-testing -- ping -c 2 192.168.123.5  # Home LAN
kubectl exec -it $POD -n network-testing -- ping -c 2 10.10.20.5    # Trusted zone
kubectl exec -it $POD -n network-testing -- ping -c 2 10.10.30.5    # DMZ zone
kubectl exec -it $POD -n network-testing -- ping -c 2 10.10.50.5    # Monitoring zone

# Should be ALLOWED (internet)
kubectl exec -it $POD -n network-testing -- ping -c 2 8.8.8.8
```

### DMZ Zone (should be DENIED from Home LAN)

```bash
# Get DMZ zone test pod
POD=$(kubectl get pod -n network-testing -l zone=dmz -o jsonpath='{.items[0].metadata.name}')

# Should be DENIED by deny-dmz-to-home-lan rule
kubectl exec -it $POD -n network-testing -- ping -c 2 192.168.123.5

# Should be ALLOWED (Trusted and internet)
kubectl exec -it $POD -n network-testing -- ping -c 2 10.10.20.5    # Trusted zone
kubectl exec -it $POD -n network-testing -- ping -c 2 8.8.8.8       # Internet
```

### Trusted Zone (should be ALLOWED everywhere)

```bash
# Get trusted zone test pod
POD=$(kubectl get pod -n network-testing -l zone=trusted -o jsonpath='{.items[0].metadata.name}')

# Should be ALLOWED (no restrictions)
kubectl exec -it $POD -n network-testing -- ping -c 2 192.168.123.5  # Home LAN
kubectl exec -it $POD -n network-testing -- ping -c 2 10.10.30.5    # DMZ
kubectl exec -it $POD -n network-testing -- ping -c 2 8.8.8.8       # Internet
```

## Monitoring with Hubble

Watch host firewall drops in real-time:

```bash
# Monitor all DROPPED verdicts on the untrusted worker
kubectl -n kube-system exec -it ds/cilium -- hubble observe -f --verdict DROPPED \
  --from-pod network-testing/host-firewall-test-untrusted

# Filter for specific traffic
kubectl -n kube-system exec -it ds/cilium -- hubble observe -f --verdict DROPPED \
  --verdict ALLOWED \
  --from-pod network-testing/host-firewall-test-untrusted
```
- **On Control Plane:** Verify control plane network isolation

## Cleanup

To remove these pods, delete the namespace:

```bash
kubectl delete namespace network-testing
```

Or let Flux handle reconciliation by removing the reference from the infrastructure Kustomization.
