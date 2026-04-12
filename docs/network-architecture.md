# Network Architecture Documentation

## Overview

This homelab uses a **simplified two-network architecture** where the control plane manages **physical isolation** and workers run on a single workload network. **Network zone isolation** (Trusted, DMZ, Untrusted, Monitoring) is enforced at the **pod level using Cilium Network Policies** with namespace labels.

The cluster relies on **two isolated networks** created using Linux bridges on the Proxmox host: Management (vmbr0) for the control plane and Workload (vmbr1) for all workers.

### Network Topology

```
┌─────────────────────┐
│  Home Network       │
│  192.168.123.0/24   │
│  (Management LAN)   │
└──────────┬──────────┘
           │
    ┌──────▼──────────────┐
    │   Fritzbox Router   │  Static Routes:
    │  192.168.123.1      │  - 10.10.20.0/24 → 192.168.123.20
    └──────┬──────────────┘
           │ ens18: 192.168.123.20/24
    ┌──────▼──────────────────────────────────────────┐
    │  Control Plane Node (Bastion)                   │
    │  192.168.123.20                                 │
    │  IP Forwarding: ENABLED                         │
    │                                                 │
    │  ens18 (mgmt): 192.168.123.20/24                │
    │  ens19 (workload): 10.10.20.2/24                │
    └──┬──────────────────────────────────────────────┘
       │
    ens19: 10.10.20.2
     (bridge)
       │
       ├─────────────────────────────────────────────┐
       │                                             │
    ┌──▼──┐                                       ┌──▼──┐
    │ Wrkr │                                       │ Wrkr │
    │  1   │                                       │  2   │
    │.21   │  Pods with zone labels:               │.22   │
    │      │  - network-zone: trusted              │      │
    │      │  - network-zone: dmz                  │      │
    │      │  - network-zone: untrusted            │      │
    │      │  - network-zone: monitoring           │      │
    └──────┘                                       └──────┘
```


## Routing Concepts

### Routes are Unidirectional

Each node independently decides how to route packets based on its routing table. However, **symmetric routing** occurs when both the forward and return paths are correctly configured.

### Symmetric Routing Example: Ping from Management Machine to Worker Node

#### Forward Path (Request)
```
Your Machine (192.168.123.x)
  ├─ Packet destination: 10.10.30.21
  ├─ Routing table lookup: "10.10.30.0/24 → gateway 192.168.123.20"
  └─ Sends to: 192.168.123.20
       ↓
Control Plane (192.168.123.20)
  ├─ Receives on ens18 (192.168.123.0/24 network)
  ├─ Packet destination: 10.10.30.21
  ├─ Routing table: "10.10.30.0/24 is directly connected on ens20"
  ├─ IP Forwarding: ENABLED → forwards the packet
  └─ Sends to: ens20
       ↓
Worker DMZ Node (10.10.30.21)
  └─ Receives the ping request
```

#### Return Path (Reply)
```
Worker DMZ Node (10.10.30.21)
  ├─ Packet source: 10.10.30.21, destination: 192.168.123.x
  ├─ Routing table lookup: "192.168.123.0/24 → gateway 10.10.30.2"
  └─ Sends to: 10.10.30.2
       ↓
Control Plane (192.168.123.20)
  ├─ Receives on ens20 (10.10.30.0/24 network)
  ├─ Packet destination: 192.168.123.x
  ├─ Routing table: "192.168.123.0/24 is directly connected on ens18"
  ├─ IP Forwarding: ENABLED → forwards the packet
  └─ Sends to: ens18
       ↓
Your Machine (192.168.123.x)
  └─ Receives the ping reply
```

**Key Points:**
- Each routing decision is **unidirectional** (forward or backward)
- Return path works because the worker knows to send replies to control plane (10.10.x.2)
- Control plane's IP forwarding enabled on both interfaces enables bidirectional flow
- Fritzbox static routes ensure packets reach control plane from management network

---

## Network Setup Details

We create **two distinct networks** using **Linux Bridges** on the Proxmox host:

### vmbr0: Management Network (192.168.123.0/24)

**Purpose:** Connects to your home LAN (FritzBox). Used for Proxmox management, Kubernetes API access, and MetalLB LoadBalancer pool.

**Configuration:**
- Gateway IP on Proxmox host: 192.168.123.8
- Proxmox node: 192.168.123.8
- Control Plane VM (Talos): 192.168.123.20
- MetalLB IP pool: 192.168.123.21-29 (advertised by control plane MetalLB speaker)
- FritzBox router: 192.168.123.1
- FritzBox forwards external ports 80/443 to 192.168.123.21-29

**Network Path:**
```
Internet ← FritzBox (80/443→192.168.123.21-29) ← vmbr0 ← MetalLB/Traefik
```

### vmbr1: Workload Network (10.10.20.0/24)

**Purpose:** All worker nodes run on this single network. **Network isolation** (Trusted, DMZ, Untrusted, Monitoring) is enforced at the **pod level** using Cilium Network Policies with namespace labels.

**Configuration:**
- Gateway IP on Proxmox host: 10.10.20.1
- Control Plane interface: 10.10.20.2 (acts as gateway for workers)
- Worker Node 1 (Talos): 10.10.20.21
- Worker Node 2 (Talos): 10.10.20.22
- All nodes can reach: 192.168.123.0/24 (management) and internet

**Network Zones (Pod-Level Isolation):**

Namespace labels define security zones; Cilium Network Policies enforce isolation:

| Zone | Namespace Label | Purpose | Pod Connectivity |
|------|-----------------|---------|----------------------|
| **Trusted** | `network-zone: trusted` | Internal services (Home Assistant, NAS, file servers) with home LAN access | Can reach: Home LAN, Management, Internet |
| **DMZ** | `network-zone: dmz` | Public-facing services (Traefik Ingress). Must be isolated from home LAN | Can reach: Internet, explicit Trusted pods; Blocked: Home LAN, Untrusted |
| **Untrusted** | `network-zone: untrusted` | Experimental workloads, development, testing, sandboxing | Can reach: Internet only; Blocked: Home LAN, Trusted, DMZ, Monitoring |
| **Monitoring** | `network-zone: monitoring` | Observability infrastructure (Prometheus, Grafana, Hubble). Pull-based metrics collection | Can reach: All zones (pull-only); Others cannot push to Monitoring |

**Security Model:**
- **Physical isolation**: Single network reduces VM overhead while maintaining security via Cilium
- **Pod-level isolation**: Namespace labels + Cilium Network Policies enforce zone boundaries
- **Deep packet inspection**: Cilium eBPF monitors all pod traffic by zone
- **Defense in depth**: Optional host firewall rules provide additional layer

## Network Routing Architecture

### Proxmox Host as Router

The Proxmox host acts as a **software router** between the two networks:

```
Proxmox Host (192.168.123.8)
├─ vmbr0 (192.168.123.8/24)    ← Management network
└─ vmbr1 (10.10.20.1/24)       ← Workload network (all workers)

IP Forwarding: ENABLED
```

**Configuration file:** See Proxmox host `/etc/network/interfaces` for exact Linux bridge setup.

### Static Routes on Admin Machine

Your admin machine needs static routes to reach worker nodes:

```bash
# From admin machine on home LAN
ip route add 10.10.20.0/24 via 192.168.123.20  # Workload network via control plane
```

Or configure in your home router (FritzBox):
- Destination: 10.10.20.0/24 → Gateway: 192.168.123.20

### Control Plane Routing

The control plane node has connections to **both networks** and routes traffic between them:

```
Control Plane Node (192.168.123.20)
├─ ens18: 192.168.123.20/24  (vmbr0 - management)
└─ ens19: 10.10.20.2/24      (vmbr1 - workload)

All interfaces with IP forwarding enabled
```

Worker nodes use the control plane's workload interface IP (10.10.20.2) as their default gateway.

### Traffic Flow Examples

#### Example 1: Admin Machine → DMZ Worker Pod

```
Admin (192.168.123.x on home LAN)
  ↓ (destination 10.10.30.21)
Home Router (FritzBox)
  ↓ (uses static route: 10.10.30.0/24 → 192.168.123.20)
Proxmox Host (router, forwards to vmbr2)
  ↓
Control Plane (ens20: 10.10.30.2)
  ↓ (forwards to ens20)
DMZ Worker (10.10.30.21)
```

#### Example 2: Trusted Pod → DMZ Pod (via Kubernetes)

```
Trusted Pod (10.10.20.x)
  ↓ (destination: DMZ service IP on Kubernetes network)
Control Plane (has Cilium routing for Kubernetes networks)
  ↓ (Cilium routes to DMZ worker)
DMZ Worker (10.10.30.x)
  ↓
DMZ Pod
```

#### Example 3: External Internet → Traefik (via MetalLB)

```
External User on Internet
  ↓ (destination 192.168.123.21-29, ports 80/443)
FritzBox Router
  ↓ (forwards to 192.168.123.21-29 on vmbr0)
MetalLB Pool (advertised by control plane speaker)
  ↓
Traefik Pod (on DMZ worker)
  ↓ (routes to backend service on DMZ or trusted network)
Backend Pod
```

## Detailed Node Configuration

### Control Plane Node (192.168.123.20)

**Role:** Bastion host and router between management and worker networks

**System Settings:**
- IP Forwarding: `net.ipv4.ip_forward = 1`
- IPv6 Forwarding: `net.ipv6.conf.all.forwarding = 1`

**Network Interfaces:**

| Interface | Network | IP Address | Subnet | Gateway | Purpose |
|-----------|---------|-----------|--------|---------|---------|
| ens18 | Management | 192.168.123.20 | 192.168.123.0/24 | 192.168.123.1 | Connected to home LAN (Fritzbox) |
| ens19 | Trusted | 10.10.20.2 | 10.10.20.0/24 | 10.10.20.1 | Internal services (Home Assistant, etc.) |
| ens20 | DMZ | 10.10.30.2 | 10.10.30.0/24 | 10.10.30.1 | Public-facing services (Traefik ingress) |
| ens21 | Untrusted | 10.10.40.2 | 10.10.40.0/24 | 10.10.40.1 | Experimental/testing workloads |
| ens22 | Monitoring | 10.10.50.2 | 10.10.50.0/24 | 10.10.50.1 | Monitoring infrastructure |

**Routes:**

| Destination | Next Hop | Interface | Type |
|------------|----------|-----------|------|
| 192.168.123.0/24 | - | ens18 | Directly connected |
| 10.10.20.0/24 | - | ens19 | Directly connected |
| 10.10.30.0/24 | - | ens20 | Directly connected |
| 10.10.40.0/24 | - | ens21 | Directly connected |
| 10.10.50.0/24 | - | ens22 | Directly connected |
| 0.0.0.0/0 | 192.168.123.1 | ens18 | Default (via Fritzbox) |

---

### Worker Nodes (talos-worker-1, talos-worker-2)

All worker nodes run on the same workload network. **Network isolation** (Trusted, DMZ, Untrusted, Monitoring) is enforced at the **pod level** via namespace labels and Cilium Network Policies.

**Worker Node 1:** talos-worker-1
**IP Address:** 10.10.20.21
**Network:** 10.10.20.0/24 (Workload)

**Worker Node 2:** talos-worker-2
**IP Address:** 10.10.20.22
**Network:** 10.10.20.0/24 (Workload)

**Network Interfaces (identical for all workers):**

| Interface | Network | IP Address | Subnet | Gateway | Purpose |
|-----------|---------|-----------|--------|---------|----------|
| ens18 | Workload | 10.10.20.21 (or .22) | 10.10.20.0/24 | 10.10.20.1 | Worker node communication |

**Routes:**

| Destination | Next Hop | Gateway | Interface | Purpose |
|------------|----------|---------|-----------|---------|
| 0.0.0.0/0 | - | 10.10.20.1 | ens18 | Default: traffic to unknown networks goes to Proxmox bridge (external internet) |
| 192.168.123.0/24 | - | **10.10.20.2** | ens18 | **CRITICAL:** Management network traffic routed to control plane (bastion) |

**Why 10.10.20.2 for Management Network?**

The worker must route replies back through the control plane (10.10.20.2) instead of the Proxmox bridge (10.10.20.1) because:
1. The bridge connects to Proxmox VMs, not to the management network
2. Only the control plane has the ens18 interface connected to 192.168.123.0/24
3. Without this route, replies from workers to 192.168.123.x would be lost

**Pod-Level Network Zones:**

Network isolation (Trusted, DMZ, Untrusted, Monitoring) is enforced via namespace labels, not physically separate workers. Apply labels to namespaces:

```bash
kubectl label namespace traefik network-zone=dmz
kubectl label namespace homeassistant network-zone=trusted
kubectl label namespace experimental network-zone=untrusted
kubectl label namespace monitoring network-zone=monitoring
```

Cilium Network Policies read these labels and enforce isolation rules.



---

## Fritzbox Configuration

### Static Routes

The Fritzbox must have a static route pointing to the control plane for the workload network:

```
Destination Network: 10.10.20.0/24  → Gateway: 192.168.123.20 (Control Plane)
```

**How to Configure:**
1. Login to Fritzbox: `http://192.168.123.1` or `fritz.box`
2. Navigate to: **Home Network** → **Network Settings** (or **Advanced** → **Network**)
3. Find **"Static Routes"** or **"IPv4 Routes"** section
4. Add each route with the table above

---

## Traffic Flow Analysis

### Scenario 1: Management Machine → Worker Node (e.g., talosctl)

```
Management (192.168.123.x)
  └─ Destination: 10.10.20.21 (worker)
     └─ Fritzbox lookup: "10.10.20.0/24 → 192.168.123.20"
        └─ Control Plane (192.168.123.20)
           └─ Destination: 10.10.20.21
              └─ Local route: "10.10.20.0/24 on ens19"
                 └─ Forwards via ens19 to Worker (10.10.20.21)
```

### Scenario 2: Worker Node → Management Machine (e.g., reply to talosctl)

```
Worker (10.10.20.21)
  └─ Destination: 192.168.123.x
     └─ Local route: "192.168.123.0/24 via 10.10.20.2"
        └─ Control Plane (192.168.123.20, ens19)
           └─ Destination: 192.168.123.x
              └─ Local route: "192.168.123.0/24 on ens18"
                 └─ Forwards via ens18 to Management (192.168.123.x)
```

### Scenario 3: Worker Node → Internet (e.g., software updates)

```
Worker (10.10.20.21)
  └─ Destination: 8.8.8.8 (external)
     └─ Local route: "0.0.0.0/0 via 10.10.20.1"
        └─ Proxmox Bridge (10.10.20.1)
           └─ [Proxmox host networking]
              └─ Internet
```

---

## Exposing Services Directly to the Home LAN (Without Traefik)

Some services need to be reachable from the home LAN directly — not via Traefik — because they use non-HTTP protocols (e.g., DNS on UDP/53) or because per-client source IP visibility is required (e.g., Pi-hole client groups, parental filtering).

### The `cluster-services` MetalLB Pool

The `cluster-services` pool (`10.10.20.100–10.10.20.150`) is reserved for services that need direct home LAN access. IPs are on the workload network (`10.10.20.0/24`) for two reasons:

1. **Workers can advertise them via ARP** — worker nodes are on `10.10.20.0/24` natively, so MetalLB L2 speakers on workers can respond to ARP for these IPs. The control-plane is not involved.
2. **Already routable from the home LAN** — the FritzBox static route `10.10.20.0/24 → 192.168.123.20` means home LAN clients can reach `10.10.20.x` addresses via the control-plane as a router. No additional routing changes needed.

```
Home LAN client (192.168.123.x)
  │  request → 10.10.20.100
  ▼
FritzBox: static route → 192.168.123.20 (control-plane, acting as router)
  │  IP forwarding → workload network (10.10.20.0/24)
  ▼
Worker: ARP for 10.10.20.100 answered by MetalLB speaker on the pod's node
  │  externalTrafficPolicy: Local → no SNAT
  ▼
Pod sees source = 192.168.123.x  ✓
```

### The Constraint: `externalTrafficPolicy: Local` is Required

With `externalTrafficPolicy: Cluster` (the default), Cilium's kube-proxy replacement SNATs forwarded traffic using the forwarding node's internal (`cilium_host`) IP as the masquerade source. The destination pod sees this internal IP instead of the real client. Per-client features in applications like Pi-hole become useless.

`externalTrafficPolicy: Local` disables SNAT — traffic is only delivered to nodes with a **local** endpoint, and the original source IP is preserved end-to-end. MetalLB automatically elects the node running the pod as the L2 speaker.

### Current Allocations

| IP | Service | Namespace |
|----|---------|-----------|
| `10.10.20.100` | `pihole-dns` | `pi-hole` |

### Implementation

**1. Use the `cluster-services` pool** (already configured in `flux/infrastructure/config/metallb/metallb-config.yaml`)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: my-namespace
  annotations:
    metallb.io/address-pool: cluster-services
spec:
  type: LoadBalancer
  loadBalancerIP: 10.10.20.1xx   # pick a free IP from the pool
  externalTrafficPolicy: Local
  selector:
    app.kubernetes.io/name: my-app
  ports:
    - port: <port>
      targetPort: <port>
      protocol: <TCP|UDP>
```

**2. Network policy allowing home LAN ingress**

With `externalTrafficPolicy: Local`, the real client IP is preserved, so `fromCIDR` works correctly:

```yaml
ingress:
  - fromCIDR:
      - 192.168.123.0/24
    toPorts:
      - ports:
          - port: "<port>"
            protocol: TCP   # repeat for UDP if needed
```

No `fromEntities` or CIDR workarounds for SNAT are needed — the source is always a real home LAN IP.

### Example: Pi-hole DNS

Pi-hole requires client IP visibility for per-device blocking rules and parental filtering. It uses UDP/TCP port 53, which cannot go through Traefik.

**Files:**
- `flux/infrastructure/config/metallb/metallb-config.yaml` — `cluster-services` pool and L2Advertisement
- `flux/untrusted/pi-hole/service.yaml` — `pihole-dns` on `10.10.20.100` with `externalTrafficPolicy: Local`
- `flux/untrusted/pi-hole/network-policies.yaml` — ingress from `192.168.123.0/24` on port 53

Traffic flow:
```
Home LAN device (e.g. 192.168.123.50)
  │  UDP query → 10.10.20.100:53
  ▼
FritzBox: static route → control-plane → workload network
  ▼
Worker running Pi-hole (MetalLB speaker answers ARP for 10.10.20.100)
  │  Cilium: LoadBalancer DNAT → Pi-hole pod (local, no SNAT)
  ▼
Pi-hole pod sees source = 192.168.123.50  ✓ (per-client rules work)
```

**Why not `externalTrafficPolicy: Cluster`?** Cilium SNATs forwarded traffic using the `cilium_host` IP of the forwarding node (a `10.244.x.x` address). This IP has a cluster-internal Cilium identity — `fromCIDR` rules do not apply to it. All DNS queries arrive from the same masquerade IP regardless of actual client, breaking per-client features.

---

## TCP Proxy for VPN-Bridged Services

### Problem

Services on remote networks accessed via FritzBox VPN (e.g., Horsmar Home Assistant at 192.168.178.10) cannot be reached directly from Kubernetes pods. The issue is asymmetric routing:

1. Pod traffic is SNATed to worker node IP (10.10.20.x)
2. Traffic reaches remote service via VPN
3. Remote service replies to 10.10.20.x
4. Remote FritzBox doesn't know how to route to 10.10.20.0/24 (can't add static route with VPN gateway)

### Solution: TCP Proxy on Management LAN

Run a lightweight TCP proxy (LXC container) on the management network (192.168.123.x). The proxy:
- Listens on management LAN (reachable from cluster)
- Forwards to remote VPN destination
- Remote service sees traffic from management LAN IP (routable via VPN)

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Traefik Pod    │────▶│   ha-proxy LXC  │────▶│  FritzBox VPN   │────▶│  Horsmar HA     │
│  (10.244.x.x)   │     │ 192.168.123.11  │     │                 │     │ 192.168.178.10  │
└─────────────────┘     └─────────────────┘     └─────────────────┘     └─────────────────┘
         │                      │                                               │
         │    SNAT to           │         VPN tunnel                           │
         │    10.10.20.x        │         routes to                            │
         │                      │         192.168.178.x                        │
         │                      │                                               │
         └──────────────────────┴───────────────────────────────────────────────┘
                          Reply path works because remote sees
                          source IP 192.168.123.11 (routable via VPN)
```

### ha-proxy LXC Setup

**Container:** Alpine Linux LXC on Proxmox
- IP: 192.168.123.11
- Resources: 64MB RAM, 1 CPU, 512MB disk

**Installation:**
```bash
apk add socat

cat > /etc/init.d/ha-proxy << 'EOF'
#!/sbin/openrc-run
command="/usr/bin/socat"
command_args="TCP-LISTEN:8123,fork,reuseaddr TCP:192.168.178.10:8123"
command_background=true
pidfile="/run/ha-proxy.pid"
EOF

chmod +x /etc/init.d/ha-proxy
rc-update add ha-proxy default
service ha-proxy start
```

### Kubernetes Configuration

**Bridge Backend** (flux/dmz/traefik/bridge-backends.yaml):
```yaml
apiVersion: v1
kind: Endpoints
metadata:
  name: ext-homeassistant-horsmar
  namespace: traefik
subsets:
  - addresses:
      - ip: 192.168.123.11  # ha-proxy LXC
    ports:
      - name: http
        port: 8123
```

**Network Policy Exception** (flux/infrastructure/config/network-policies/zone-policies.yaml):

Add proxy IP to `deny-dmz-to-home-lan` exceptions:
```yaml
except:
  - 192.168.123.11/32 # ha-proxy LXC (Horsmar HA)
```

**Traefik Egress Policy** (flux/dmz/traefik/network-policy.yaml):
```yaml
- toCIDR:
  - 192.168.123.11/32
  toPorts:
  - ports:
    - port: "8123"
      protocol: TCP
```

### Adding More VPN Services

To proxy additional VPN-bridged services:

1. Add socat listener in ha-proxy LXC (or create dedicated proxy)
2. Add Kubernetes Service/Endpoints pointing to proxy IP
3. Add proxy IP to zone isolation exceptions (if needed)
4. Add port to Traefik network policy

---

## Security Implications

### Network Isolation
- The workload network (10.10.20.0/24) is not directly accessible from the management network
- All management access must go through the control plane bastion
- Pod-level isolation (Cilium policies) enforces zone boundaries within the workload network
- This creates multiple security checkpoints: physical network + pod-level policies

### Pod-Level Security (Cilium)
- Default-deny network policies block all inter-pod traffic unless explicitly allowed
- Namespace labels (`network-zone: [trusted|dmz|untrusted|monitoring]`) define security zones
- Cilium policies can enforce zone-to-zone  rules (e.g., DMZ blocked from Home LAN)
- Violations are logged and visible via Hubble network observability

### Control Plane as Single Point of Access
- If the control plane goes down, management access to workers is lost
- Mitigation: Use SSH ProxyJump/tunneling, or implement secondary bastion

### Default Routes Matter
- Workers use `0.0.0.0/0 → 10.10.20.1` for internet access
- This keeps external traffic separate from management network traffic
- Management network traffic explicitly routed to control plane ensures return path

---

## Verification Commands

### Check Control Plane Routing
```bash
talosctl -n 192.168.123.20 get routes
talosctl -n 192.168.123.20 get addresses
talosctl read /proc/sys/net/ipv4/ip_forward --nodes 192.168.123.20
```

### Check Worker Routing
```bash
talosctl -n 10.10.20.21 get routes
talosctl -n 10.10.20.21 get addresses
```

### Test Connectivity
```bash
# From management network
ping 10.10.20.2           # Control plane workload interface
ping 10.10.20.21          # Worker 1
ping 10.10.20.22          # Worker 2
talosctl apply-config --insecure --nodes 10.10.30.21 --file talos-worker-dmz-1.yaml
```

---

## Troubleshooting

### Issue: Cannot ping worker nodes from management network

**Check Fritzbox static routes:**
```bash
# Verify on Fritzbox (via web UI or SSH)
ip route show
```

**Check control plane IP forwarding:**
```bash
talosctl read /proc/sys/net/ipv4/ip_forward --nodes 192.168.123.20
# Should return: 1
```

**Check control plane routing table:**
```bash
talosctl -n 192.168.123.20 get routes | grep "10.10.30"
# Should show: 10.10.30.0/24 is directly connected on ens20
```

**Check worker routing to management network:**
```bash
talosctl -n 10.10.30.21 get routes | grep "192.168.123"
# Should show: 192.168.123.0/24 via 10.10.30.2 on ens18
```

### Issue: Worker can reach internet but not management network

**Check worker routes are applied:**
```bash
talosctl -n 10.10.30.21 get routes
# Verify 192.168.123.0/24 route with gateway 10.10.30.2
```

**Reapply worker config and reboot:**
```bash
talosctl apply-config --insecure --nodes 10.10.30.21 --file talos-worker-dmz-1.yaml
talosctl reboot --nodes 10.10.30.21
```

### Issue: Control plane cannot forward traffic between networks

**Verify all interfaces are up:**
```bash
talosctl -n 192.168.123.20 get links
# All ens18-22 should have OPER STATE: up
```

**Check for firewall/network policies:**
```bash
# If using Cilium network policies, verify they allow inter-node traffic
kubectl get cnp -A
```
