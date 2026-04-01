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
# Note: Extract first document only (split on ---) to handle multiple documents in newer Talos provider versions
locals {
  controlplane_config_patched = yamldecode(split("---", data.talos_machine_configuration.controlplane.machine_configuration)[0])
  worker_config_patched       = yamldecode(split("---", data.talos_machine_configuration.worker.machine_configuration)[0])

  # Base manifests directory
  manifests_base_dir = "${path.module}/../talos/manifests"
}

# Read manifests for each control plane and worker node
locals {
  controlplane_manifests = {
    for node in var.control_plane : node.name => try(
      [for file in fileset("${local.manifests_base_dir}/${node.name}", "*.yaml") : file],
      []
    )
  }

  worker_manifests = {
    for node in var.worker_nodes : node.name => try(
      [for file in fileset("${local.manifests_base_dir}/${node.name}", "*.yaml") : file],
      []
    )
  }


}

# Save control plane configurations to files
resource "local_file" "controlplane_config" {
  for_each = { for node in var.control_plane : node.name => node }

  filename = "${path.module}/../talos/gen/${each.value.name}.yaml"
  content = join("---\n", concat(
    [yamlencode(
      merge(
        local.controlplane_config_patched,
        {
          cluster = merge(
            local.controlplane_config_patched.cluster,
            {
              // For Cilium: disable kube-proxy
              // see https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium
              proxy = {
                disabled = true
              },
              controllerManager = merge(
                lookup(local.controlplane_config_patched.cluster, "controllerManager", {}),
                {
                  // Bind to all interfaces so Prometheus can scrape metrics (port 10257).
                  // By default Talos binds to 127.0.0.1, making the endpoint unreachable
                  // from pods outside the node host network.
                  extraArgs = merge(
                    lookup(lookup(local.controlplane_config_patched.cluster, "controllerManager", {}), "extraArgs", {}),
                    { "bind-address" = "0.0.0.0" }
                  )
                }
              ),
              scheduler = merge(
                lookup(local.controlplane_config_patched.cluster, "scheduler", {}),
                {
                  // Bind to all interfaces so Prometheus can scrape metrics (port 10259).
                  // Same reason as controllerManager above.
                  extraArgs = merge(
                    lookup(lookup(local.controlplane_config_patched.cluster, "scheduler", {}), "extraArgs", {}),
                    { "bind-address" = "0.0.0.0" }
                  )
                }
              ),
              network = merge(
                local.controlplane_config_patched.cluster.network,
                {
                  cni = {
                    name = "none"
                  }
                }
              )
            }
          ),
          machine = merge(
            local.controlplane_config_patched.machine,
            {
              install = merge(
                local.controlplane_config_patched.machine.install,
                {
                  disk  = "/dev/vda"
                  image = "factory.talos.dev/installer-secureboot/${talos_image_factory_schematic.this.id}:${var.talos_version}" # SecureBoot installer with qemu-guest-agent from Image Factory
                  wipe  = false                                                                                                   # Indicates if the installation disk should be wiped at installation time.
                }
              ),
              sysctls = {
                "net.ipv4.ip_forward"          = "1"
                "net.ipv6.conf.all.forwarding" = "1" # Optional: for IPv6
                # Swap tuning for performance
                "vm.swappiness"   = "130"  # Increased from default 60 - makes kernel more willing to use swap
                "vm.page-cluster" = "0"    # Disable swap read-ahead for non-rotational devices
              },
              features = merge(
                local.controlplane_config_patched.machine.features,
                {
                  stableHostname = false
                  hostDNS = {
                    enabled = true
                    // When forwardKubeDNSToHost is enabled, Talos Linux allocates IP address 169.254.116.108 for the host DNS server,
                    // and kube-dns service is configured to use this IP address as the upstream DNS server
                    // https://docs.siderolabs.com/talos/v1.12/networking/host-dns
                    forwardKubeDNSToHost = true
                    // Host DNS can be configured to resolve Talos cluster member names to IP addresses, so that the
                    // host can communicate with the cluster members by name
                    // https://docs.siderolabs.com/talos/v1.12/networking/host-dns#resolving-talos-cluster-member-names
                    resolveMemberNames = true

                  }
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

  filename = "${path.module}/../talos/gen/${each.value.name}.yaml"
  content = join("---\n", concat(
    [yamlencode(
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
                  image = "factory.talos.dev/installer-secureboot/${talos_image_factory_schematic.this.id}:${var.talos_version}" # SecureBoot installer with qemu-guest-agent from Image Factory
                  wipe  = false                                                                                                   # Indicates if the installation disk should be wiped at installation time.
                }
              ),
              features = merge(
                local.controlplane_config_patched.machine.features,
                {
                  stableHostname = false
                }
              ),
              // Swap tuning for performance
              sysctls = {
                "vm.swappiness"   = "130"  # Increased from default 60 - makes kernel more willing to use swap
                "vm.page-cluster" = "0"    # Disable swap read-ahead for non-rotational devices
              },
              kernel = {
                modules = [
                  { name = "nvme_tcp" },
                  { name = "vfio_pci" },
                ]
              },
              kubelet = merge(
                local.worker_config_patched.machine.kubelet,
                {
                  extraConfig = {
                    memorySwap = {
                      swapBehavior = "LimitedSwap"  # Allow containers to use swap
                    }
                  },
                  extraMounts = [
                    {
                      destination = "/var/lib/longhorn"
                      type        = "bind"
                      source      = "/var/lib/longhorn"
                      options     = ["bind", "rshared", "rw"]
                    },
                  ]
                }
              )
            }
          )
        }
      )
    )],
    [
      for manifest_file in local.worker_manifests[each.value.name] :
      file("${local.manifests_base_dir}/${each.value.name}/${manifest_file}")
    ]
  ))
}

# Save talosconfig to file for reference
resource "local_file" "talosconfig" {
  filename = "${path.module}/../talosconfig"
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
