# Network Testing Pods

This directory contains Flux manifests for deploying network analysis pods on all cluster nodes for testing and validating Cilium network policies.

## Pods Deployed

- **DaemonSet: `network-analysis`** — Runs on all nodes (including control plane) with full network analysis capabilities
  - Uses `nicolaka/netshoot` image with tools: `tcpdump`, `curl`, `dig`, `nslookup`, `netcat`, `ip`, `ifconfig`, `iptables`, etc.
  - Runs with `hostNetwork: true` and `privileged: true` to access host network namespace
  - Useful for debugging network policies, packet analysis, and connectivity tests

## Usage

Once deployed, you can connect to any pod and perform network analysis:

```bash
# List all network testing pods
kubectl get pods -n network-testing

# Execute commands on a specific pod
kubectl exec -it <pod-name> -n network-testing -- bash

# Examples:
kubectl exec -it network-analysis-xxxxx -n network-testing -- tcpdump -i eth0
kubectl exec -it network-analysis-xxxxx -n network-testing -- curl http://some-service
kubectl exec -it network-analysis-xxxxx -n network-testing -- dig kubernetes.default
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
