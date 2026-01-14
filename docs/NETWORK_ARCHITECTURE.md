# Network Architecture Documentation

## Overview

This homelab uses a **bastion node pattern** where the control plane node acts as a router and bastion host, enabling management access to isolated worker networks from the home network.

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
    │                     │  - 10.10.30.0/24 → 192.168.123.20
    │                     │  - 10.10.40.0/24 → 192.168.123.20
    │                     │  - 10.10.50.0/24 → 192.168.123.20
    └──────┬──────────────┘
           │ ens18: 192.168.123.20/24
    ┌──────▼──────────────────────────────────────────────────────────┐
    │  Control Plane Node (Bastion)                                   │
    │  192.168.123.20                                                 │
    │  IP Forwarding: ENABLED                                         │
    │                                                                  │
    │  ens18 (mgmt): 192.168.123.20/24                                │
    │  ens19 (trusted): 10.10.20.1/24                                 │
    │  ens20 (dmz): 10.10.30.1/24                                     │
    │  ens21 (untrusted): 10.10.40.1/24                               │
    │  ens22 (monitoring): 10.10.50.1/24                              │
    └──┬──────────────┬──────────────┬──────────────┬──────────────┘
       │              │              │              │
    ens19         ens20          ens21          ens22
 10.10.20.1   10.10.30.1     10.10.40.1     10.10.50.1
  (bridge)     (bridge)       (bridge)       (bridge)
       │              │              │              │
       │              │              │              │
    ┌──▼──┐       ┌──▼──┐       ┌──▼──┐       ┌──▼──┐
    │Wrkr │       │Wrkr │       │Wrkr │       │Wrkr │
    │Trstd│       │DMZ  │       │Untst│       │Mon  │
    │.21  │       │.21  │       │.21  │       │.21  │
    └─────┘       └─────┘       └─────┘       └─────┘
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

### Worker Nodes (Trusted, DMZ, Untrusted, Monitoring)

All worker nodes follow the same pattern. Example for DMZ Worker:

**Node:** talos-worker-dmz-1
**IP Address:** 10.10.30.21
**Network:** 10.10.30.0/24 (DMZ)

**Network Interfaces:**

| Interface | Network | IP Address | Subnet | Gateway | Purpose |
|-----------|---------|-----------|--------|---------|---------|
| ens18 | DMZ | 10.10.30.21 | 10.10.30.0/24 | 10.10.30.1 | Worker node communication |

**Routes:**

| Destination | Next Hop | Gateway | Interface | Purpose |
|------------|----------|---------|-----------|---------|
| 0.0.0.0/0 | - | 10.10.30.1 | ens18 | Default: traffic to unknown networks goes to Proxmox bridge (external internet) |
| 192.168.123.0/24 | - | **10.10.30.2** | ens18 | **CRITICAL:** Management network traffic routed to control plane (bastion) |

**Why 10.10.30.2 for Management Network?**

The worker must route replies back through the control plane (10.10.30.2) instead of the Proxmox bridge (10.10.30.1) because:
1. The bridge connects to Proxmox VMs, not to the management network
2. Only the control plane has the ens18 interface connected to 192.168.123.0/24
3. Without this route, replies from workers to 192.168.123.x would be lost

#### Trusted Worker (talos-worker-trusted-1)
- IP: 10.10.20.21
- Gateway for management: 10.10.20.2 (control plane ens19)

#### DMZ Worker (talos-worker-dmz-1)
- IP: 10.10.30.21
- Gateway for management: 10.10.30.2 (control plane ens20)

#### Untrusted Worker (talos-worker-untrusted-1)
- IP: 10.10.40.21
- Gateway for management: 10.10.40.2 (control plane ens21)

#### Monitoring Worker (talos-worker-monitoring-1)
- IP: 10.10.50.21
- Gateway for management: 10.10.50.2 (control plane ens22)

---

## Fritzbox Configuration

### Static Routes

The Fritzbox must have static routes pointing to the control plane for all worker networks:

```
Destination Network: 10.10.20.0/24  → Gateway: 192.168.123.20 (Control Plane)
Destination Network: 10.10.30.0/24  → Gateway: 192.168.123.20 (Control Plane)
Destination Network: 10.10.40.0/24  → Gateway: 192.168.123.20 (Control Plane)
Destination Network: 10.10.50.0/24  → Gateway: 192.168.123.20 (Control Plane)
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
  └─ Destination: 10.10.30.21 (worker)
     └─ Fritzbox lookup: "10.10.30.0/24 → 192.168.123.20"
        └─ Control Plane (192.168.123.20)
           └─ Destination: 10.10.30.21
              └─ Local route: "10.10.30.0/24 on ens20"
                 └─ Forwards via ens20 to Worker (10.10.30.21)
```

### Scenario 2: Worker Node → Management Machine (e.g., reply to talosctl)

```
Worker (10.10.30.21)
  └─ Destination: 192.168.123.x
     └─ Local route: "192.168.123.0/24 via 10.10.30.2"
        └─ Control Plane (192.168.123.20, ens20)
           └─ Destination: 192.168.123.x
              └─ Local route: "192.168.123.0/24 on ens18"
                 └─ Forwards via ens18 to Management (192.168.123.x)
```

### Scenario 3: Worker Node → Internet (e.g., software updates)

```
Worker (10.10.30.21)
  └─ Destination: 8.8.8.8 (external)
     └─ Local route: "0.0.0.0/0 via 10.10.30.1"
        └─ Proxmox Bridge (10.10.30.1)
           └─ [Proxmox host networking]
              └─ Internet
```

---

## Security Implications

### Network Isolation
- Worker networks (10.10.x.0/24) are not directly accessible from the management network
- All management access must go through the control plane bastion
- This creates an additional security checkpoint for accessing sensitive nodes

### Control Plane as Single Point of Access
- If the control plane goes down, management access to workers is lost
- Mitigation: Use SSH ProxyJump/tunneling, or implement secondary bastion

### Default Routes Matter
- Workers use `0.0.0.0/0 → 10.10.30.1` for internet access
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
talosctl -n 10.10.30.21 get routes
talosctl -n 10.10.30.21 get addresses
```

### Test Connectivity
```bash
# From management network
ping 10.10.30.2           # Control plane DMZ interface
ping 10.10.30.21          # DMZ worker node
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
