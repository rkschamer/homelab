# Modifications on PVE Node (Bare Metal)

This contains the modification, which needed to be done on the PVE node and what is not covered by any automation.

## Terraform User

We use the [Proxmox Terraform provider](https://registry.terraform.io/providers/Telmate/proxmox/latest/docs) to create K8s node VMs.
The documentation suggests to create a dedicated Terraform user, to avoid using cluster-wide admin users:

```bash
pveum role add terraform-role -privs "Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Pool.Allocate Pool.Audit Sys.Audit Sys.Console Sys.Modify VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Migrate VM.PowerMgmt SDN.Use"
pveum user add terraform@pve --password <password>
pveum aclmod / -user terraform@pve -role terraform-role
pveum user token add terraform-prov@pve mytoken
```

## Add Network Bridges to `/etc/network/interfaces`

Network bridges are used to created separate networks for K8s node VMs.
This approach acts as a "software VLAN" setup and does not require a managed switch.
That's the main building block of the network isolation concept.

`/etc/network/interfaces` content:

```
auto lo
iface lo inet loopback

iface enp2s0 inet manual

# Management bridge (connected to FritzBox LAN)
auto vmbr0
iface vmbr0 inet static
        address 192.168.123.8/24
        gateway 192.168.123.1
        bridge-ports enp2s0
        bridge-stp off
        bridge-fd 0
        # Allow return traffic for established connections from DMZ
        post-up iptables -I FORWARD -i vmbr0 -o vmbr2 -m state --state RELATED,ESTABLISHED -j ACCEPT
        post-down iptables -D FORWARD -i vmbr0 -o vmbr2 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Trusted network bridge (isolated)
auto vmbr1
iface vmbr1 inet static
    address 10.10.20.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s '10.10.20.0/24' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '10.10.20.0/24' -o vmbr0 -j MASQUERADE

# DMZ bridge (isolated)
auto vmbr2
iface vmbr2 inet static
    address 10.10.30.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s '10.10.30.0/24' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '10.10.30.0/24' -o vmbr0 -j MASQUERADE
    # Allow Traefik (10.10.30.10) to access Home Assistant (192.168.123.10:8123)
    post-up iptables -I FORWARD -i vmbr2 -o vmbr0 -s 10.10.30.10 -d 192.168.123.10 -p tcp --dport 8123 -j ACCEPT
    post-down iptables -D FORWARD -i vmbr2 -o vmbr0 -s 10.10.30.10 -d 192.168.123.10 -p tcp --dport 8123 -j ACCEPT
    # Allow Traefik (10.10.30.10) to access Synology NAS (192.168.123.5:5001)
    post-up iptables -I FORWARD -i vmbr2 -o vmbr0 -s 10.10.30.10 -d 192.168.123.5 -p tcp --dport 5001 -j ACCEPT
    post-down iptables -D FORWARD -i vmbr2 -o vmbr0 -s 10.10.30.10 -d 192.168.123.5 -p tcp --dport 5001 -j ACCEPT
    # Explicitly drop all other traffic from DMZ to trusted networks for security
    post-up iptables -A FORWARD -i vmbr2 -o vmbr0 -j DROP
    post-down iptables -D FORWARD -i vmbr2 -o vmbr0 -j DROP
    post-up iptables -A FORWARD -i vmbr2 -o vmbr1 -j DROP
    post-down iptables -D FORWARD -i vmbr2 -o vmbr1 -j DROP

# Untrusted bridge (isolated, internet-only)
auto vmbr3
iface vmbr3 inet static
    address 10.10.40.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s '10.10.40.0/24' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '10.10.40.0/24' -o vmbr0 -j MASQUERADE
    # Block access from untrusted to any internal network
    post-up   iptables -I FORWARD -i vmbr3 -d '192.168.0.0/16' -j DROP
    post-up   iptables -I FORWARD -i vmbr3 -d '10.0.0.0/8' -j DROP
    post-down iptables -D FORWARD -i vmbr3 -d '192.168.0.0/16' -j DROP
    post-down iptables -D FORWARD -i vmbr3 -d '10.0.0.0/8' -j DROP

# Monitoring bridge (isolated, monitoring-outbound)
auto vmbr4
iface vmbr4 inet static
    address 10.10.50.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s '10.10.50.0/24' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '10.10.50.0/24' -o vmbr0 -j MASQUERADE
    # Allow monitoring outbound to other networks
    post-up   iptables -A FORWARD -i vmbr4 -o vmbr0 -j ACCEPT
    post-up   iptables -A FORWARD -i vmbr4 -o vmbr1 -j ACCEPT
    post-up   iptables -A FORWARD -i vmbr4 -o vmbr2 -j ACCEPT
    post-up   iptables -A FORWARD -i vmbr4 -o vmbr3 -j ACCEPT
    post-down iptables -D FORWARD -i vmbr4 -o vmbr0 -j ACCEPT
    post-down iptables -D FORWARD -i vmbr4 -o vmbr1 -j ACCEPT
    post-down iptables -D FORWARD -i vmbr4 -o vmbr2 -j ACCEPT
    post-down iptables -D FORWARD -i vmbr4 -o vmbr3 -j ACCEPT
    # Block any other networks from initiating traffic to monitoring, EXCEPT for Grafana from the management LAN
    post-up   iptables -A FORWARD -i vmbr0 -o vmbr4 -p tcp --dport 3000 -d 10.10.50.0/24 -j ACCEPT
    post-down iptables -D FORWARD -i vmbr0 -o vmbr4 -p tcp --dport 3000 -d 10.10.50.0/24 -j ACCEPT
    post-up   iptables -A FORWARD -d 10.10.50.0/24 -i vmbr0 -j DROP
    post-up   iptables -A FORWARD -d 10.10.50.0/24 -i vmbr1 -j DROP
    post-up   iptables -A FORWARD -d 10.10.50.0/24 -i vmbr2 -j DROP
    post-up   iptables -A FORWARD -d 10.10.50.0/24 -i vmbr3 -j DROP
    post-down iptables -D FORWARD -d 10.10.50.0/24 -i vmbr0 -j DROP
    post-down iptables -D FORWARD -d 10.10.50.0/24 -i vmbr1 -j DROP
    post-down iptables -D FORWARD -d 10.10.50.0/24 -i vmbr2 -j DROP
    post-down iptables -D FORWARD -d 10.10.50.0/24 -i vmbr3 -j DROP
```
