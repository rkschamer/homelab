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
└── _out/                # Generated configs (created on `terraform apply`)
    ├── controlplane.yaml
    ├── worker-*.yaml
    └── talosconfig
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

worker_nodes = [
  {
    name           = "worker-dmz"
    vmid           = 201
    ip_address     = "10.10.30.21"
    disk_size_gb   = 64
    memory         = 4096
    cores          = 4
    network_bridge = "vmbr2"  # DMZ network
    network_zone   = "dmz"
    gateway        = "10.10.30.1"
    subnet_prefix  = 24
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
- Generate machine configurations and save to `_out/`
- Output paths to generated config files

### 3. Boot Control Plane from ISO

The VM will automatically boot from the ISO and enter **maintenance mode**. You'll see in the Proxmox console:

```
Welcome to Talos!
Run "talosctl apply-config" to configure the node

Endpoint: <DHCP_IP>
```

**Note the DHCP IP displayed in the console.**

### 4. Apply Configuration to Control Plane

Configure `talosctl` and apply the control plane config:

```bash
export TALOSCONFIG="$(pwd)/talos/talosconfig"
export CONTROL_PLANE_IP=<DHCP_IP_from_console>

talosctl config endpoint $CONTROL_PLANE_IP
talosctl config node $CONTROL_PLANE_IP

talosctl apply-config --insecure --nodes $CONTROL_PLANE_IP --file talos/controlplane.yaml
```

The `--insecure` flag is used because the node hasn't fully joined the cluster yet. Once applied, Talos will:
- Install to disk (`/dev/sda`)
- Reboot automatically
- Start the Kubernetes control plane

Monitor progress in the Proxmox console. The node will reboot and stabilize.

### 5. Bootstrap the Cluster

Once the control plane is stable (check Proxmox console), bootstrap etcd:

```bash
talosctl bootstrap
```

This initializes the Kubernetes API. Wait 30-60 seconds for it to become ready.

### 6. Retrieve Kubeconfig

```bash
talosctl kubeconfig .
export KUBECONFIG="$(pwd)/kubeconfig"
kubectl get nodes
```

You should see the control plane node listed.

### 7. Configure Worker Nodes

For each worker node, repeat the process:

1. **Get DHCP IP** from Proxmox console
2. **Apply the worker config**:
   ```bash
   export WORKER_IP=<DHCP_IP_from_console>
   talosctl apply-config --insecure --nodes $WORKER_IP --file _out/worker-<name>.yaml
   ```
3. **Wait for installation and reboot** (~30-60 seconds)

Workers automatically register with the cluster once configured.

### 8. Verify All Nodes

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

## Configuration Files Generated

After `terraform apply`, the `_out/` directory contains:

- **controlplane.yaml**: Machine config for the control plane node
- **worker-*.yaml**: Machine configs for each worker node (one per file)
- **talosconfig**: Talos client config (sensitive, used by `talosctl`)

These are generated from the Talos machine configuration data sources, with patches applied for disk and hostname settings.

## Network Architecture

- **vmbr0** (Management): 192.168.123.0/24 - Home LAN access
- **vmbr1** (Trusted): 10.10.20.0/24 - Internal services (e.g., Home Assistant)
- **vmbr2** (DMZ): 10.10.30.0/24 - Public-facing services (Traefik, Ingress)
- **vmbr3** (Untrusted): 10.10.40.0/24 - Experiments (isolated, internet-only)
- **vmbr4** (Monitoring): 10.10.50.0/24 - Monitoring stack

Workers are assigned to networks via the `network_bridge` variable.

## Extending the Configuration

### Add More Workers

Edit `terraform.tfvars` and add to the `worker_nodes` list:

```hcl
worker_nodes = [
  # ... existing workers
  {
    name           = "worker-new"
    vmid           = 203
    ip_address     = "10.10.20.25"
    disk_size_gb   = 64
    memory         = 8192
    cores          = 4
    network_bridge = "vmbr1"  # Trusted network
    network_zone   = "trusted"
    gateway        = "10.10.20.1"
    subnet_prefix  = 24
  },
]
```

Then rerun `terraform apply` and follow step 7 to configure the new worker.

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
