# horsmar-proxy LXC

Lightweight socat TCP proxy on the management LAN that bridges cluster traffic to
Horsmar Home Assistant (192.168.178.10) via the FritzBox VPN. It exists to fix an
asymmetric-routing problem: pods SNAT to worker IPs (10.10.20.x) that the remote
FritzBox cannot route back to, while the proxy's management-LAN IP is routable
through the VPN.

For the full routing rationale and the cluster-side configuration (bridge backend
Service/EndpointSlice, network policy exceptions, Traefik egress policy), see
[docs/network-architecture.md](../../docs/network-architecture.md), section
"TCP Proxy for VPN-Bridged Services".

## Container

- Alpine Linux LXC on Proxmox
- IP: 192.168.123.11 (static, management LAN / vmbr0)
- Resources: 64 MB RAM, 1 CPU, 512 MB disk

## Install

```sh
apk add socat

cat > /etc/init.d/horsmar-proxy << 'EOF'
#!/sbin/openrc-run
command="/usr/bin/socat"
command_args="TCP-LISTEN:8123,fork,reuseaddr TCP:192.168.178.10:8123"
command_background=true
pidfile="/run/horsmar-proxy.pid"
EOF

chmod +x /etc/init.d/horsmar-proxy
rc-update add horsmar-proxy default
service horsmar-proxy start
```

## Adding more proxied services

1. Add another socat listener (new OpenRC service on a distinct port).
2. Add a Kubernetes Service/EndpointSlice pointing to 192.168.123.11
   (`flux/dmz/traefik/bridge-backends.yaml`).
3. Add the port to the Traefik egress policy and, if needed, the zone isolation
   exceptions (see network-architecture.md).

## Recovery

The container holds no state — recreate the LXC, run the install block, done.
The IP must remain 192.168.123.11: it is hardcoded in the bridge backends and
network policy exceptions.
