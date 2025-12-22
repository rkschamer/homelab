# Talos Machine Secrets - generates all necessary secrets for the cluster
resource "talos_machine_secrets" "this" {}

# Talos Client Configuration (talosconfig)
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [var.control_plane_ip]
}

# Talos Machine Configuration for Control Plane
data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.control_plane_ip}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
}

# Talos Machine Configuration for Worker nodes
data "talos_machine_configuration" "worker" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.control_plane_ip}:6443"
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
}

# Apply configuration to control plane node
resource "talos_machine_configuration_apply" "controlplane" {
  depends_on                  = [proxmox_virtual_environment_vm.control_plane]
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = var.control_plane_ip
  config_patches = [
    templatefile("${path.module}/patches/install-disk-and-hostname.yaml.tpl", {
      hostname     = "talos-control-plane-1"
      install_disk = "/dev/sda"
    })
  ]
}

# Apply configuration to worker nodes
resource "talos_machine_configuration_apply" "worker" {
  depends_on                  = [proxmox_virtual_environment_vm.workers]
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  for_each                    = { for node in var.worker_nodes : node.name => node }
  node                        = "192.168.123.${21 + index(var.worker_nodes, each.value)}"
  config_patches = [
    templatefile("${path.module}/patches/install-disk-and-hostname.yaml.tpl", {
      hostname     = each.value.name
      install_disk = "/dev/sda"
    })
  ]
}

# Bootstrap the Talos cluster
resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.controlplane]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.control_plane_ip
}

# Retrieve kubeconfig
resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.control_plane_ip
}

# Outputs
output "talosconfig" {
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
  description = "Talos client configuration"
}

output "kubeconfig" {
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
  description = "Kubernetes kubeconfig"
}
