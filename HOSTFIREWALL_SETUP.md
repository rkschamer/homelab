# Host Firewall Setup and Testing Guide

## What's New

I've created comprehensive host firewall policies for your Kubernetes cluster based on the Cilium documentation. These policies protect the node OS and host namespaces from unauthorized network access.

## Files Created

1. **flux/infrastructure/network-policies/host-firewall-policies.yaml**
   - 5 main policies protecting control plane and worker nodes
   - Allows required Kubernetes and VXLAN communication
   - Denies unexpected traffic

2. **flux/infrastructure/network-policies/kustomization.yaml**
   - Kustomize configuration to deploy zone and host firewall policies

3. **flux/infrastructure/network-policies/README.md**
   - Consolidated documentation with zone isolation and host firewall guidance

4. **Updated flux/infrastructure/kustomization.yaml**
   - Uses `network-policies` as the single policy entrypoint

## Policy Overview

### Policies Created

| Policy Name | Target | Purpose |
|-------------|--------|---------|
| `allow-control-plane-ingress` | Control plane host | Allows incoming traffic (API, Talos API, VXLAN) |
| `allow-control-plane-egress` | Control plane host | Allows outgoing traffic to cluster and external |
| `allow-worker-ingress` | Worker node hosts | Allows incoming cluster communication |
| `allow-worker-egress` | Worker node hosts | Allows outgoing API and external traffic |
| `allow-host-health-checks` | All nodes | Allows Cilium health checks |

### Key Allowed Traffic

**Control Plane Ingress:**
- Management LAN (192.168.123.0/24): Talos API (50000), kube-apiserver (6443), etcd (2379-2380)
- Workload network (10.10.20.0/24): kube-apiserver, kubelet API, VXLAN, health checks
- Any: DNS (53)

**Worker Ingress:**
- Management LAN: Talos API (50000) only
- Workload network: kubelet API (10250), VXLAN (8472), health checks (4240)
- Any: DNS (53)

**All Egress:**
- Allows cluster-internal communication
- Allows DNS globally
- Allows HTTP/HTTPS to external networks for image pulls and updates

## Prerequisites

### 1. Verify Host Firewall is Enabled

Your cilium-release.yaml already has:
```yaml
hostFirewall:
  enabled: true
```

If needed, you can explicitly set the network device:
```yaml
hostFirewall:
  enabled: true
devices: "ens18,ens19"
```

### 2. Verify Node Labels

Check that your nodes have the correct labels:

```bash
kubectl get nodes --show-labels | grep node-role
```

Should show:
```
talos-controlplane-1   control-plane=
talos-worker-1         worker=
talos-worker-2         worker=
```

If labels are missing, add them:
```bash
kubectl label node talos-controlplane-1 node-role.kubernetes.io/control-plane=""
kubectl label node talos-worker-1 node-role.kubernetes.io/worker=""
kubectl label node talos-worker-2 node-role.kubernetes.io/worker=""
```

## Deployment Steps

### 1. Commit Changes to Git

The policies are now configured to deploy via Flux. Commit and push:

```bash
git add flux/infrastructure/network-policies/
git add flux/infrastructure/kustomization.yaml
git commit -m "Add host firewall policies for node-level network security"
git push
```

### 2. Let Flux Deploy (or Force it)

Flux will automatically detect and deploy the policies. To force immediate deployment:

```bash
flux reconcile source git flux-system
flux reconcile kustomization infrastructure
```

### 3. Verify Policies Are Applied

```bash
# Check if policies exist
kubectl get CiliumClusterwideNetworkPolicy

# Expected output:
# NAME                              AGE
# allow-control-plane-egress        ...
# allow-control-plane-ingress       ...
# allow-worker-egress               ...
# allow-worker-ingress              ...
# allow-host-health-checks          ...
```

### 4. Check Policy Details

```bash
kubectl describe CiliumClusterwideNetworkPolicy allow-control-plane-ingress
```

## Testing Connectivity

### Test 1: Talos API Access from Management Network

```bash
# From your admin machine (192.168.123.x)
talosctl -n 192.168.123.20 get nodes    # Should work (uses port 50000)

# From an untrusted pod
kubectl run -it --rm debug --image=alpine --restart=Never -- sh
# Inside pod:
nc -zv 192.168.123.20 50000    # Should timeout (different network)
```

### Test 2: kube-apiserver Access

```bash
# From kubectl client
kubectl get nodes             # Should work

# From a pod
kubectl run -it --rm debug --image=alpine --restart=Never -- sh
# Inside pod:
wget -O- https://kubernetes.default.svc.cluster.local:443   # Should work
```

### Test 3: Inter-Node Communication

```bash
# Launch a pod on each node
kubectl run -it --rm debug-pod --image=alpine --restart=Never -- sh

# Inside pod on worker-1, test connectivity to worker-2
ping 10.10.20.22            # Should work (VXLAN, pod-level policy allows)
```

### Test 4: Blocked Connections (Should Fail)

```bash
# From a pod with network-zone: untrusted
# (if you have one)

# Try to reach a pod with network-zone: trusted
ping <trusted-pod-ip>       # Should timeout (blocked by pod policy, AND might be blocked by host firewall if in different network)

# Try to reach home LAN
ping 192.168.123.1          # Should fail (blocked by host firewall)
```

## Monitoring and Troubleshooting

### Monitor Denied Connections

```bash
# Watch for policy violations
kubectl logs -n kube-system -l k8s-app=cilium -f | grep -i deny

# Or get a specific pod
CILIUM_POD=$(kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n kube-system $CILIUM_POD -f | grep -i "policy.*drop"
```

### Use Hubble for Visualization

```bash
# Port-forward to Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 4000:80

# Open browser to http://localhost:4000
# Watch traffic flows and policy enforcement
```

### Check Host Endpoint Status

```bash
# Get host endpoint ID
CILIUM_POD=$(kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
HOST_EP_ID=$(kubectl exec -n kube-system $CILIUM_POD -- cilium-dbg endpoint get -l reserved:host -o jsonpath='{[0].id}')

# Check policy status
kubectl exec -n kube-system $CILIUM_POD -- cilium-dbg endpoint config $HOST_EP_ID | grep -E "PolicyAuditMode|Policy.*"

# Monitor traffic on host endpoint
kubectl exec -n kube-system $CILIUM_POD -- cilium-dbg monitor --related-to $HOST_EP_ID --type=Drop
```

### Disable Audit Mode (if needed)

If you see unexpected denials while policies are being tested:

```bash
CILIUM_POD=$(kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
HOST_EP_ID=$(kubectl exec -n kube-system $CILIUM_POD -- cilium-dbg endpoint get -l reserved:host -o jsonpath='{[0].id}')

# Disable audit mode to enforce policies strictly
kubectl exec -n kube-system $CILIUM_POD -- cilium-dbg endpoint config $HOST_EP_ID PolicyAuditMode=false
```

## Common Issues and Solutions

### Issue: Cannot Access Talos API

**Symptoms:** `talosctl` commands time out or fail to connect

**Solution:**
1. Verify Management LAN range in policy (192.168.123.0/24)
2. Check your admin machine is in that range
3. Verify Talos API port 50000 is allowed:
   ```bash
   kubectl describe CiliumClusterwideNetworkPolicy allow-control-plane-ingress | grep -A5 "50000"
   ```
4. Test connectivity directly:
   ```bash
   nc -zv 192.168.123.20 50000  # Should connect
   ```

### Issue: Pods Cannot Reach kube-apiserver

**Symptoms:** Kubelet errors about API connectivity

**Solution:**
1. Verify workers can reach 192.168.123.20:6443
2. Check workload network CIDR in policy (10.10.20.0/24)
3. Test DNS resolution
4. Monitor with Hubble

### Issue: VXLAN Traffic Blocked

**Symptoms:** Inter-pod communication fails, pods can't reach services

**Solution:**
1. Verify VXLAN port 8472/UDP is allowed in both policies
2. Check Cilium is running and healthy:
   ```bash
   kubectl get pods -n kube-system -l k8s-app=cilium
   ```
3. Monitor traffic:
   ```bash
   kubectl exec -n kube-system <cilium-pod> -- cilium-dbg monitor --type=drop | grep 8472
   ```

## Next Steps

1. **Test thoroughly** in your non-production environment first
2. **Monitor the logs** for the first 24 hours to catch any unexpected blocks
3. **Document any custom changes** you make to the policies
4. **Review quarterly** to ensure policies match your current infrastructure
5. **Consider adding DNS layer-7 policies** if you need DNS-based restrictions (advanced)

## References

- Full policy documentation: [flux/infrastructure/network-policies/README.md](./flux/infrastructure/network-policies/README.md)
- Cilium Host Policies: https://docs.cilium.io/en/stable/security/policy/language/#host-policies
- Your network architecture: [docs/network-architecture.md](../../docs/network-architecture.md)
- Pod-level policies: [flux/infrastructure/network-policies/](./network-policies/)
