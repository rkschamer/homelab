# Talos Machine Secrets - generates all necessary secrets for the cluster
resource "talos_machine_secrets" "this" {}

# Talos Client Configuration (talosconfig)
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [var.control_plane[0].ip_address]
}

# Talos Machine Configuration for Control Plane
data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.control_plane[0].ip_address}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
}

# Talos Machine Configuration for Worker nodes
data "talos_machine_configuration" "worker" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.control_plane[0].ip_address}:6443"
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
}

# Generate patched control plane configuration
locals {
  controlplane_config_patched = yamldecode(data.talos_machine_configuration.controlplane.machine_configuration)
  worker_config_patched       = yamldecode(data.talos_machine_configuration.worker.machine_configuration)

  # Base manifests directory
  manifests_base_dir = "${path.module}/talos/manifests"
}

# Read manifests for each control plane node
locals {
  controlplane_manifests = {
    for node in var.control_plane : node.name => try(
      [for file in fileset("${local.manifests_base_dir}/${node.name}", "*.yaml") : file],
      []
    )
  }

  # Debug: Show what manifests were found
  debug_manifests_dir          = local.manifests_base_dir
  debug_controlplane_manifests = local.controlplane_manifests
}

# Save control plane configurations to files
resource "local_file" "controlplane_config" {
  for_each = { for node in var.control_plane : node.name => node }

  filename = "${path.module}/talos/gen/${each.value.name}.yaml"
  content = join("---\n", concat(
    [yamlencode(
      merge(
        local.controlplane_config_patched,
        {
          cluster = merge(
            local.controlplane_config_patched.cluster,
            {
              proxy = null # Disable kube-proxy since Cilium eBPF mode handles service load balancing
            }
          ),
          machine = merge(
            local.controlplane_config_patched.machine,
            {
              install = merge(
                local.controlplane_config_patched.machine.install,
                {
                  disk  = "/dev/vda"
                  image = "factory.talos.dev/installer/${talos_image_factory_schematic.this.id}:${var.talos_version}" # Custom image with qemu-guest-agent from Image Factory
                  wipe  = false                                                                                       # Indicates if the installation disk should be wiped at installation time.
                }
              )
            },
            {
              features = merge(
                local.controlplane_config_patched.machine.features,
                {
                  stableHostname = false
                }
              )
            }
          )
        },
      )
    )],
    [
      for manifest_file in local.controlplane_manifests[each.value.name] :
      file("${local.manifests_base_dir}/${each.value.name}/${manifest_file}")
    ]
  ))
}

# Save worker node configurations to files
resource "local_file" "worker_config" {
  for_each = { for node in var.worker_nodes : node.name => node }

  filename = "${path.module}/talos/gen/${each.value.name}.yaml"
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
                image = "factory.talos.dev/installer/${talos_image_factory_schematic.this.id}:${var.talos_version}" # Custom image with qemu-guest-agent from Image Factory
                wipe  = false                                                                                       # Indicates if the installation disk should be wiped at installation time.
              }
            ),
            network = {
              hostname = each.value.name
              interfaces = [
                {
                  interface = "eth0"
                  dhcp      = false
                  addresses = [
                    {
                      address = "${each.value.ip_address}/${each.value.subnet_prefix}"
                    }
                  ]
                  routes = [
                    {
                      destination = "0.0.0.0/0"
                      gateway     = each.value.gateway
                    }
                  ]
                }
              ]
              nameservers = ["8.8.8.8", "1.1.1.1"]
            },
            labels = {
              "workload-type" = each.value.network_zone
              "network-zone"  = each.value.network_zone
            }
          }
        )
      }
    )
  )
}

# Save talosconfig to file for reference
resource "local_file" "talosconfig" {
  filename = "${path.module}/talos/gen/talosconfig"
  content  = data.talos_client_configuration.this.talos_config
}

# Outputs
output "talosconfig" {
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
  description = "Talos client configuration"
}

output "controlplane_config_files" {
  value       = { for name, config in local_file.controlplane_config : name => config.filename }
  description = "Paths to control plane configuration files"
}

output "worker_config_files" {
  value       = { for name, config in local_file.worker_config : name => config.filename }
  description = "Paths to worker node configuration files"
}

output "talosconfig_file" {
  value       = local_file.talosconfig.filename
  description = "Path to talosconfig file"
}
