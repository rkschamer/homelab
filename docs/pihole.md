# Pi-hole DNS Server

Pi-hole runs in the `pi-hole` namespace (untrusted zone) and serves as the primary DNS resolver for the home LAN. It uses Unbound as a sidecar for recursive upstream resolution.

## Network Architecture

### IP Addressing

Pi-hole is exposed via a MetalLB LoadBalancer service on a dedicated IP from the `cluster-services` pool:

```
DNS endpoint:  10.10.20.100:53  (metallb.io/address-pool: cluster-services)
Web UI:        via Traefik ingress (ClusterIP service pihole-web)
```

The `cluster-services` pool (`10.10.20.100–10.10.20.150`) uses IPs on the workload network rather than the management network. This is intentional — see [Routing Constraint](#routing-constraint) below.

### Routing Constraint

All traffic destined for `10.10.20.0/24` (the workload network) is routed through the control plane node:

```
Home LAN client (192.168.123.x)
        │
        │  query to 10.10.20.100:53
        ▼
   FritzBox Router
        │
        │  static route: 10.10.20.0/24 → 192.168.123.20
        ▼
   Control Plane (192.168.123.20)
        │
        │  IP forwarding → 10.10.20.0/24 via ens19
        ▼
   Worker Node (Pi-hole pod)
```

The FritzBox has a static route directing all `10.10.20.0/24` traffic to the control plane (`192.168.123.20`), which has IP forwarding enabled and acts as a router between the management and workload networks.

### Why externalTrafficPolicy: Local Does Not Work

A natural first approach would be `externalTrafficPolicy: Local` — MetalLB would elect the worker running Pi-hole as the ARP responder for `10.10.20.100`, and traffic would arrive there with the original source IP preserved (no SNAT).

This does **not** work here. Cilium's BPF load balancer hooks attach at the TC (traffic control) layer, which runs **before** the Linux routing table lookup. When a packet destined for `10.10.20.100` arrives at the control plane, Cilium intercepts it on ingress to `ens18` and checks for a local backend. Since Pi-hole runs on a worker (not the control plane), there is no local backend — Cilium drops the packet.

`externalTrafficPolicy: Local` would only work if Pi-hole ran on the control plane itself, which is not desirable.

### externalTrafficPolicy: Cluster and SNAT

`externalTrafficPolicy: Cluster` is required. With this setting, Cilium on the control plane:

1. **DNATs** the destination: `10.10.20.100:53` → Pi-hole pod IP (e.g. `10.244.2.5:53`)
2. **SNATs** the source: `192.168.123.x` → `10.244.0.43` (the control plane's `cilium_host` IP)
3. Forwards the packet to the worker via VXLAN tunnel

SNAT is necessary to ensure the return path is symmetric. Without it, the Pi-hole pod would reply directly to `192.168.123.x` via the worker's default route — bypassing the control plane and breaking connection tracking.

## Cilium Network Policy

### The SNAT Identity Problem

With SNAT in place, the Pi-hole pod sees packets sourced from `10.244.0.43`, not from the original home LAN client. In Cilium's VXLAN tunnel mode, the **security identity is embedded in the tunnel header** by the forwarding node (the control plane), not derived from the source IP on the receiving end.

When the control plane forwards a packet from a home LAN client (`world` identity), it embeds `world` in the tunnel header. The worker's Cilium reads this embedded identity for policy enforcement — the ipcache CIDR lookup is bypassed entirely. This means:

- `fromCIDR: 192.168.123.0/24` — does **not** match (CIDR lookup bypassed by tunnel identity)
- `fromCIDR: 10.244.0.0/24` — does **not** match (same reason)
- `fromEntities: remote-node` — does **not** match (`10.244.0.43` carries `world` identity, not `remote-node`)
- `fromEntities: world` — **matches** (directly matches the tunnel-embedded identity)

### Applied Policy

The DNS ingress rule uses `fromEntities: world`:

```yaml
- fromEntities:
    - world
  toPorts:
    - ports:
        - port: "53"
          protocol: TCP
        - port: "53"
          protocol: UDP
```

This is safe despite its broad appearance: `10.10.20.100` is only reachable from the home LAN via the FritzBox static route. There is no public internet path to this IP.

## Alternative: hostPort for Source IP Preservation

If preserving the original client IP at Pi-hole is important (e.g. for per-client query logging), the `hostPort` approach avoids SNAT entirely.

**How it works:**

- Pin Pi-hole to a specific worker via `nodeAffinity` (e.g. `10.10.20.21`)
- Add `hostPort: 53` to the container spec
- Configure DNS clients to use the worker's real IP instead of `10.10.20.100`

Traffic flow:
```
Home LAN client → 10.10.20.21:53
        ↓  (FritzBox static route → control plane)
   Control Plane: forwards to 10.10.20.21 (real host IP, no Cilium BPF LB interception)
        ↓
   Worker 10.10.20.21: Cilium DNATs hostPort → Pi-hole pod (no SNAT)
        ↓
   Pi-hole sees original source IP 192.168.123.x
```

Because `10.10.20.21` is a real node IP (not a virtual service IP), Cilium's BPF load balancer does not intercept the packet on the control plane. Normal IP forwarding applies.

**Trade-offs:**

| | Current (LoadBalancer + `world`) | hostPort + nodeAffinity |
|---|---|---|
| Dedicated DNS IP | `10.10.20.100` (stable) | Worker IP `10.10.20.x` (node-bound) |
| Source IP at Pi-hole | `10.244.0.43` (SNAT'd) | `192.168.123.x` (original) |
| Network policy | `fromEntities: world` | `fromCIDR: 192.168.123.0/24` |
| Complexity | Low | Requires nodeAffinity + DNS reconfiguration |
| Availability | Pod can reschedule freely | Tied to the pinned worker node |

## Related Files

- `flux/untrusted/pi-hole/deployment.yaml` — Pi-hole + Unbound sidecar
- `flux/untrusted/pi-hole/service.yaml` — LoadBalancer (DNS) and ClusterIP (web UI) services
- `flux/untrusted/pi-hole/network-policies.yaml` — Cilium ingress/egress rules
- `flux/infrastructure/config/metallb/metallb-config.yaml` — `cluster-services` IP pool definition
