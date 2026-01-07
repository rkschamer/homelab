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

# Generate patched control plane configuration
locals {
  controlplane_config_patched = yamldecode(data.talos_machine_configuration.controlplane.machine_configuration)
  worker_config_patched       = yamldecode(data.talos_machine_configuration.worker.machine_configuration)
}

# Save control plane configuration to file
resource "local_file" "controlplane_config" {
  filename = "${path.module}/talos/controlplane.yaml"
  content = yamlencode(
    merge(
      local.controlplane_config_patched,
      {
        machine = merge(
          local.controlplane_config_patched.machine,
          {
            install = merge(
              local.controlplane_config_patched.machine.install,
              {
                disk  = "/dev/vda"
                image = "ghcr.io/siderolabs/installer:latest" # Allows for supplying the image used to perform the installation.
                wipe  = false                                 # Indicates if the installation disk should be wiped at installation time.
              }
            )
          }
        )
      }
    )
  )
}

# Save worker node configurations to files
resource "local_file" "worker_config" {
  for_each = { for node in var.worker_nodes : node.name => node }

  filename = "${path.module}/talos/worker-${each.value.name}.yaml"
  content = yamlencode(
    merge(
      local.worker_config_patched,
      {
        machine = merge(
          local.worker_config_patched.machine,
          {
            install = merge(
              local.worker_config_patched.machine.install,
              {
                disk  = "/dev/vda"
                image = "ghcr.io/siderolabs/installer:latest" # Allows for supplying the image used to perform the installation.
                wipe  = false                                 # Indicates if the installation disk should be wiped at installation time.
              }
            ),
            network = {
              nameservers = ["8.8.8.8", "1.1.1.1"]

            }
          }
        )
      }
    )
  )
}

# Save talosconfig to file for reference
resource "local_file" "talosconfig" {
  filename = "${path.module}/_out/talosconfig"
  content  = data.talos_client_configuration.this.talos_config
}

# Outputs
output "talosconfig" {
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
  description = "Talos client configuration"
}

output "controlplane_config_file" {
  value       = local_file.controlplane_config.filename
  description = "Path to control plane configuration file"
}

output "worker_config_files" {
  value       = { for name, config in local_file.worker_config : name => config.filename }
  description = "Paths to worker node configuration files"
}

output "talosconfig_file" {
  value       = local_file.talosconfig.filename
  description = "Path to talosconfig file"
}
