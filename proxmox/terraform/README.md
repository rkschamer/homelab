# Talos Kubernetes on Proxmox (ISO-Based Installation)

This Terraform configuration deploys a Talos Kubernetes cluster on Proxmox VE using an ISO-based boot approach. This method eliminates the need for SSH access to the Proxmox host.

## Architecture

- **Hypervisor**: Proxmox VE
- **OS**: Talos (lightweight, immutable Kubernetes OS)
- **CNI**: Cilium in eBPF mode (no kube-proxy)
- **Networking**: Multiple isolated networks (Management, Trusted, DMZ, Untrusted, Monitoring)
- **Load Balancing**: MetalLB
- **Ingress**: Traefik with ACME/Let's Encrypt

## ISO-Based Approach vs. Disk Image

| Aspect | Disk Image | ISO Boot |
|--------|-----------|----------|
| Deployment | Pre-built image attached directly to disk | ISO file attached to CDROM |
| SSH Required | Yes (to set boot disk) | No |
| VM Boot | Boots straight to running Talos | Boots to maintenance mode |
| Configuration | Applied by Terraform | Applied manually with `talosctl` |
| Workflow | Fully automated | Semi-manual (discovery + apply) |

## Prerequisites

- Terraform >= 1.0
- `talosctl` CLI installed locally
- Proxmox API token configured in `terraform.tfvars`
- Network connectivity to Proxmox API and target VMs

## Project Structure

```
.
├── main.tf              # Provider configuration
├── variables.tf         # Input variables
├── image.tf             # ISO download from Image Factory
├── nodes.tf             # VM resources (control plane + workers)
├── cluster.tf           # Talos secrets, config generation, file outputs
├── terraform.tfstate    # State file (contains sensitive data)
├── terraform.tfvars     # API credentials and cluster config
├── patches/
│   └── install-disk-and-hostname.yaml.tpl  # Config patch template
└── talos/
    ├── gen/               # Generated configs (created on `terraform apply`)
    │   ├── controlplane.yaml
    │   ├── worker-*.yaml
    │   └── talosconfig
    └── ...
```

## Quick Start

### 1. Configure Variables

Edit `terraform.tfvars`:

```hcl
proxmox_api_url           = "https://192.168.123.8:8006/api2/json"
proxmox_api_token_id      = "root@pam!terraform"
proxmox_api_token_secret  = "your-token-secret"
proxmox_node              = "proxmox"
talos_version             = "v1.11.6"
cluster_name              = "homelab"
control_plane_ip          = "192.168.123.20"
control_plane_vmid        = 200

# Worker Nodes Configuration
worker_nodes = [
  {
    name           = "worker-trusted"
    vmid           = 220
    ip_address     = "10.10.20.21"
    disk_size_gb   = 64
    memory         = 4096
    cores          = 4
    network_devices = [
      { bridge = "vmbr1", mac_address = "52:54:00:01:00:01" }  # Trusted network only
    ]
    network_zone  = "trusted"
    gateway       = "10.10.20.1"
    subnet_prefix = 24
  },
  {
    name           = "worker-dmz"
    vmid           = 221
    ip_address     = "10.10.30.21"
    disk_size_gb   = 64
    memory         = 4096
    cores          = 4
    network_devices = [
      { bridge = "vmbr2", mac_address = "52:54:00:02:00:01" }  # DMZ network only
    ]
    network_zone  = "dmz"
    gateway       = "10.10.30.1"
    subnet_prefix = 24
  },
  # ... additional worker nodes
]
```

### 2. Initialize and Apply Terraform

```bash
cd proxmox/terraform
terraform init
terraform plan
terraform apply
```

This will:
- Download the Talos ISO with custom extensions (QEMU guest agent, AMD GPU support, etc.)
- Create VMs with CDROM boot from ISO
- Generate machine configurations and save to `talos/gen/`
- Output paths to generated config files

⚠️ **Important**: After `terraform apply` completes, **remove the ISO from the CDROM of each node** in Proxmox before booting. Otherwise, nodes will keep booting into the Talos maintenance mode instead of the installed system. In the Proxmox UI:
1. Select each VM (control plane + workers)
2. Go to **Hardware** tab
3. Double-click the CDROM device
4. Select **Do not use any media** or remove the ISO
5. Confirm

Then proceed with configuring the nodes.

### 3. Generated Configuration Files

After `terraform apply`, the `talos/gen/` directory contains generated machine configurations:

- **controlplane.yaml**: Talos machine config for the control plane
- **worker-*.yaml**: Talos machine configs for each worker (one per file)
- **talosconfig**: Talos client configuration (contains cluster credentials)

**Important**: These configs are generated from Talos defaults and include standard patches (disk device, custom container image). Review and customize them before applying if needed.

### 4. Boot Control Plane from ISO

The VM will automatically boot from the ISO and enter **maintenance mode**. You'll see in the Proxmox console:

```
Welcome to Talos!
Run "talosctl apply-config" to configure the node

Endpoint: <DHCP_IP>
```

**Note the DHCP IP displayed in the console.**

### 5. Customize Configuration (Optional)

Before applying configs, you can modify them as needed:

```bash
# Edit the generated config to add custom patches
vim talos/gen/controlplane.yaml

# Common customizations:
# - Add extra kernel parameters
# - Configure additional network interfaces
# - Enable/disable specific components
# - Add custom extensions

# Edit LinkConfig manifests for worker network setup
vim talos/manifests/talos-worker-dmz-1/linkconfig.yaml
# Adjust:
# - IP addresses and subnets
# - Gateway addresses
# - DNS servers
# - Static routes
```

### 6. Apply Configuration to Control Plane

Configure `talosctl` and apply the control plane config:

```bash
export TALOSCONFIG="$(pwd)/talos/gen/talosconfig"
export CONTROL_PLANE_IP=<DHCP_IP_from_console>

talosctl config endpoint $CONTROL_PLANE_IP
talosctl config node $CONTROL_PLANE_IP

talosctl apply-config --insecure --nodes $CONTROL_PLANE_IP --file talos/gen/controlplane.yaml
```

The `--insecure` flag is used because the node hasn't fully joined the cluster yet. Once applied, Talos will:
- Install to disk (`/dev/vda`)
- Reboot automatically
- Start the Kubernetes control plane

Monitor progress in the Proxmox console. The node will reboot and stabilize.

### 7. Bootstrap the Cluster

Once the control plane is stable (check Proxmox console), bootstrap etcd:

```bash
talosctl bootstrap
```

This initializes the Kubernetes API. Wait 30-60 seconds for it to become ready.

### 8. Retrieve Kubeconfig

```bash
talosctl kubeconfig .
export KUBECONFIG="$(pwd)/talos/gen/kubeconfig"
kubectl get nodes
```

You should see the control plane node listed.

### 9. Configure Worker Nodes

For each worker node, repeat the process:

1. **Get DHCP IP** from Proxmox console
2. **Apply the worker config**:
   ```bash
   export WORKER_IP=<DHCP_IP_from_console>
   talosctl apply-config --insecure --nodes $WORKER_IP --file talos/gen/worker-<name>.yaml
   ```
3. **Wait for installation and reboot** (~30-60 seconds)

Workers automatically register with the cluster once configured.

### 10. Verify All Nodes

```bash
kubectl get nodes
talosctl nodes
```

All nodes should be `Ready` (once CNI finishes deploying).

## Troubleshooting

### Node not appearing in `kubectl get nodes`

- Verify the node appeared in `talosctl nodes`
- Check Cilium pod deployment: `kubectl get pods -n kube-system`
- Use `talosctl logs` to check node logs:
  ```bash
  talosctl logs -k kubelet
  ```

### Apply config fails with "connection refused"

- Verify the DHCP IP is correct
- Ensure the node is in maintenance mode (check Proxmox console)
- Try again—VMs sometimes take time to fully boot

### Terraform destroy fails

If `terraform destroy` exits with code 1:
- Check for lingering VM snapshots in Proxmox that might be locked
- Manually delete VMs from Proxmox UI if needed
- Cleanup state: `terraform destroy -force`

### Workers cannot reach control plane

If workers fail to join the cluster and appear stuck in maintenance mode:

1. **Verify Proxmox host routing**:
   ```bash
   sysctl net.ipv4.ip_forward
   ip route show  # Should show all vmbr bridges with their networks
   ```

2. **Check worker node logs** (from the Proxmox console in maintenance mode):
   ```bash
   # After booting ISO, check network connectivity
   ip route  # Should show 192.168.123.0/24 → <gateway> (e.g., 10.10.30.1)
   ping 192.168.123.20  # Should reach control plane
   ```

3. **Verify static routes in generated Talos config**:
   ```bash
   grep -A 10 "routes:" talos/gen/worker-*.yaml
   ```

4. **Ensure Proxmox bridge gateways are configured**:
   - Each bridge (vmbr1-4) needs a gateway IP in `/etc/network/interfaces`
   - Check with: `ip addr show` on Proxmox host

### Networking misconfiguration

If pods cannot communicate between zones:

1. **Check CiliumNetworkPolicy rules** are properly applied: `kubectl get cnp -A`
2. **Verify worker node network_zone labels**: `kubectl get nodes --show-labels`
3. **Use Hubble for network diagnosis**: `hubble observe` can show which policies are blocking traffic

## Configuration Files Generated

After `terraform apply`, the `talos/gen/` directory contains:

- **controlplane.yaml**: Machine config for the control plane node (generated from `talos.tf`)
- **worker-*.yaml**: Machine configs for each worker node (one per file, generated from `talos.tf`)
- **talosconfig**: Talos client config (sensitive, used by `talosctl` to authenticate)

**Generation Process**:
1. Terraform generates base machine configs using the Talos provider
2. Standard patches are applied (disk device, container image URL)
3. Configs are saved as clean, readable YAML files in `_out/`
4. You can review and customize before manual application via `talosctl`

This semi-automated approach gives you full control over node configuration while eliminating most manual setup work.

## Network Architecture

### Workload Isolation via Static Routes

To achieve true network isolation while maintaining cluster connectivity, workers are deployed on isolated networks and use static routes to reach the control plane:

- **vmbr0** (Management): 192.168.123.0/24 - **Control plane only**. Not connected to worker nodes directly.
- **vmbr1** (Trusted): 10.10.20.0/24 - Internal services (e.g., Home Assistant)
- **vmbr2** (DMZ): 10.10.30.0/24 - Public-facing services (Traefik, Ingress)
- **vmbr3** (Untrusted): 10.10.40.0/24 - Experiments (isolated, internet-only)
- **vmbr4** (Monitoring): 10.10.50.0/24 - Monitoring stack

**Network Connectivity**:
- Control plane: Attached to all bridges (vmbr0-4) for access to all zones
- Worker nodes: Attached **only** to their designated workload network (vmbr1-4)
- Cross-network routing: Proxmox host configured to route 192.168.123.0/24 between bridges
- Each worker adds a static route to 192.168.123.0/24 via its gateway (Proxmox host IP on the bridge)

This approach ensures:
1. **True isolation at the VM network level**: Workers cannot reach the management network directly
2. **Cluster functionality**: Workers can reach the control plane via static routing through the Proxmox host
3. **Pod-level policy enforcement**: `CiliumNetworkPolicy` further restricts pod-to-pod traffic across zones

## Proxmox Host Routing Configuration

Since worker nodes are isolated to their workload networks, the Proxmox host must be configured to route traffic between bridges. This allows workers to reach the control plane (192.168.123.0/24) via the default gateway on their respective bridges.

**For detailed networking setup instructions**, see [NETWORK_SETUP.md](../host/NETWORK_SETUP.md) for:
- Bridge configuration in `/etc/network/interfaces`
- IP forwarding and routing setup
- Firewall rules (if applicable)
- Connectivity verification steps

**Quick summary**:

**On the Proxmox host**, ensure IP forwarding is enabled:

```bash
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | tee -a /etc/sysctl.conf
```

**Network bridge configuration** (in `/etc/network/interfaces`):
Each bridge (vmbr1-4) should have its gateway IP assigned so it can route traffic between networks.

Example for the DMZ bridge (vmbr2):
```
auto vmbr2
iface vmbr2 inet static
    address 10.10.30.1
    netmask 255.255.255.0
    bridge_ports none
    bridge_stp off
    bridge_fd 0
```

Worker nodes use this gateway (10.10.30.1 for DMZ) as the next hop to reach 192.168.123.0/24.

## Talos Network Configuration (LinkConfig)

Worker nodes use [Talos LinkConfig](https://docs.siderolabs.com/talos/v1.12/reference/configuration/network/linkconfig) documents to configure network interfaces and routes.

**LinkConfig manifests** are stored in `talos/manifests/<node-name>/linkconfig.yaml` and are automatically included in the generated machine configuration when you run `terraform apply`.

**Example LinkConfig for a DMZ worker** (stored in `talos/manifests/talos-worker-dmz-1/linkconfig.yaml`):

```yaml
apiVersion: net.talos.dev/v1alpha1
kind: LinkConfig
metadata:
  name: eth0
spec:
  name: eth0
  up: true
  addresses:
    - address: 10.10.30.21/24
  routes:
    - destination: 0.0.0.0/0
      gateway: 10.10.30.1
    - destination: 192.168.123.0/24
      gateway: 10.10.30.1
---
apiVersion: net.talos.dev/v1alpha1
kind: ResolverConfig
metadata:
  name: resolvers
spec:
  servers:
    - 8.8.8.8
    - 1.1.1.1
```

**Key LinkConfig fields**:
- `name`: Interface name (e.g., eth0)
- `up`: Bring the interface up on boot
- `addresses`: Static IP addresses to assign (CIDR notation)
- `routes`: Static routes with destination and gateway

**Network isolation approach**:
1. Each worker node is attached to **only one workload network** (vmbr1-4)
2. The `LinkConfig` configures `eth0` with a static IP on that network
3. Two routes are defined:
   - Default route: `0.0.0.0/0` → workload gateway (e.g., 10.10.30.1)
   - Control plane route: `192.168.123.0/24` → same gateway (allows reaching control plane via Proxmox host routing)
4. The Proxmox host forwards traffic between bridges, enabling this routing scheme

**Customizing LinkConfig for your network**:
- Update IP addresses to match your configuration
- Adjust gateway IPs if different from the default
- Modify DNS servers in ResolverConfig if needed
- Add additional routes as required

## Extending the Configuration

### Add More Workers

Edit `terraform.tfvars` and add to the `worker_nodes` list:

```hcl
worker_nodes = [
  # ... existing workers
  {
    name           = "worker-monitoring"
    vmid           = 223
    ip_address     = "10.10.50.25"
    disk_size_gb   = 64
    memory         = 8192
    cores          = 4
    network_devices = [
      { bridge = "vmbr4", mac_address = "52:54:00:04:00:01" }  # Monitoring network only
    ]
    network_zone   = "monitoring"
    gateway        = "10.10.50.1"
    subnet_prefix  = 24
  },
]
```

Then rerun `terraform apply` and follow the configuration steps. The generated Talos config will automatically include the static route to 192.168.123.0/24 for control plane communication.

### Customize Talos Extensions

Edit `image.tf` in the `data "talos_image_factory_extensions_versions"` block to add/remove extensions:

```hcl
filters = {
  names = [
    "siderolabs/amd-ucode",
    "siderolabs/amdgpu",
    "siderolabs/qemu-guest-agent",
    # "siderolabs/my-extension"  # Add custom extensions here
  ]
}
```

## Cleanup

To destroy the cluster:

```bash
terraform destroy
```

This removes all VMs and generated configurations. State file is preserved for audit.

## References

- [Talos Linux Documentation](https://docs.siderolabs.com/talos)
- [Talos on Proxmox](https://docs.siderolabs.com/talos/v1.10/platform-specific-installations/virtualized-platforms/proxmox)
- [Image Factory](https://www.talos.dev/latest/talos-guides/install/boot-assets/#image-factory)
- [Cilium Documentation](https://docs.cilium.io/)
