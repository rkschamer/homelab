# Host Firewall Policy Analysis

## Issues Found

### 1. **Missing: Host-networked pods → Regular pods (cluster entity)**
**Problem:** Host-networked components like Cilium agents, Hubble relay need to communicate with regular pods in the cluster.

**Evidence from traffic:**
```
-> endpoint 2977 flow , identity host->28133 ... 10.244.0.167 -> 10.244.0.139:8181 (Hubble UI)
-> endpoint 2977 flow , identity host->28133 ... 10.244.0.167 -> 10.244.0.139:8080 (Hubble UI)
```

**Current policy:** Only allows ports 8080 and 8181 to cluster entity in egress. This is correct but may be incomplete.

### 2. **Missing: DNS resolution from host network**
**Problem:** When host firewall is enabled, DNS from host-networked components may be blocked.

**Current policy:**
- Control plane egress: Allows DNS to anywhere (port 53 UDP/TCP)
- Worker egress: Allows DNS to 0.0.0.0/0

**Issue:** DNS should explicitly allow `toEntities: [cluster]` for CoreDNS pods AND to kube-dns service IP.

### 3. **Missing: Longhorn inter-node traffic**
**Problem:** Longhorn manager uses ports 9500 (manager), 9502 (admission webhook) for inter-node communication. These are NOT in your policies.

**Evidence:** Longhorn manager daemonset uses ports 9500, 9502 on pod network (not host network).

**Current policy:** No explicit allowance for Longhorn ports.

### 4. **Missing: Node-to-node health probes**
**Problem:** Kubelet health probes from control plane to workers on port 10250 may be blocked.

**Current policy:**
- Control plane egress: Allows 10250 to `remote-node` entity ✅
- Worker ingress: Allows 10250 from `remote-node` entity ✅

This looks correct.

### 5. **Missing: Pods communicating back to host services**
**Problem:** Regular pods need to reach services on host network (like node-local DNS cache if enabled, or host services).

**Current policy:** No explicit ingress rules for pods → host.

### 6. **Critical: DNS to kube-dns ClusterIP**
**Problem:** kube-dns service is at 10.96.0.10. Host-networked pods need to reach this.

**Current policy:** DNS egress allows `toPorts: port 53` but doesn't explicitly allow the kube-dns ClusterIP range (10.96.0.0/12).

### 7. **Missing: Metrics Server access**
**Problem:** Metrics server (10.106.245.116:443) needs to be accessible from host-networked components.

**Current policy:** No explicit allowance for metrics server.

### 8. **Potential Issue: ICMP replies**
**Problem:** ICMP ingress allows `EchoRequest` but egress may need `EchoReply` explicitly.

**Current policy:** Egress only allows `EchoRequest`. Missing `EchoReply`.

## Recommended Fixes

### Fix 1: Add DNS to cluster services
```yaml
# In both control-plane and worker egress
- toEntities:
  - cluster
  toPorts:
  - ports:
    - port: "53"
      protocol: UDP
    - port: "53"
      protocol: TCP

# Also allow kube-dns ClusterIP range
- toCIDR:
  - 10.96.0.0/12  # Service ClusterIP range
  toPorts:
  - ports:
    - port: "53"
      protocol: UDP
    - port: "53"
      protocol: TCP
```

### Fix 2: Add Longhorn communication
```yaml
# In worker egress (workers need to talk to other workers' Longhorn)
- toEntities:
  - remote-node
  toPorts:
  - ports:
    - port: "9500"  # Longhorn manager
      protocol: TCP
    - port: "9502"  # Longhorn admission webhook
      protocol: TCP

# In worker ingress
- fromEntities:
  - remote-node
  toPorts:
  - ports:
    - port: "9500"  # Longhorn manager
      protocol: TCP
    - port: "9502"  # Longhorn admission webhook
      protocol: TCP
```

### Fix 3: Allow all traffic to/from cluster entity
Since you're using pod-level policies for zone isolation, host firewall should allow host-networked components to reach all pods:

```yaml
# In control-plane and worker egress
- toEntities:
  - cluster
```

This is a broad rule but necessary since host-networked system components need full cluster access.

### Fix 4: Add ICMP replies
```yaml
# In control-plane and worker egress
- toEntities:
  - remote-node
  icmps:
  - fields:
    - type: EchoReply
      family: IPv4

- toCIDR:
  - 192.168.123.0/24
  icmps:
  - fields:
    - type: EchoReply
      family: IPv4
```

### Fix 5: Add metrics server access
```yaml
# In worker egress
- toEntities:
  - cluster
  toPorts:
  - ports:
    - port: "443"  # Metrics server, API server in-cluster
      protocol: TCP
    - port: "10250"  # Kubelet metrics via service
      protocol: TCP
```

## Testing Strategy

1. **Apply policies incrementally:**
   - Start with DNS fixes only
   - Verify CoreDNS works
   - Add Longhorn ports
   - Verify Longhorn works
   - Add remaining fixes

2. **Monitor with Cilium:**
   ```bash
   kubectl exec -n kube-system cilium-XXX -- cilium-dbg monitor --type drop
   ```

3. **Check policy verdict:**
   ```bash
   kubectl exec -n kube-system cilium-XXX -- cilium-dbg policy get
   ```

4. **Test DNS from host-networked pod:**
   ```bash
   kubectl run -it --rm debug --image=busybox --restart=Never --overrides='{"spec":{"hostNetwork":true}}' -- nslookup kubernetes.default
   ```
