data "talos_image_factory_extensions_versions" "this" {
  talos_version = var.talos_version
  filters = {
    names = [
      "siderolabs/amd-ucode",
      "siderolabs/amdgpu",
      "siderolabs/qemu-guest-agent",
      // required for longhorn:
      "siderolabs/iscsi-tools",
      "siderolabs/util-linux-tools",
    ]
  }
}

resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode(
    {
      customization = {
        systemExtensions = {
          officialExtensions = data.talos_image_factory_extensions_versions.this.extensions_info.*.name
        }
      }
    }
  )
}

resource "proxmox_download_file" "talos_iso" {
  depends_on   = [talos_image_factory_schematic.this]
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.proxmox_node
  file_name    = "talos-${var.talos_version}-nocloud-amd64-secureboot.iso"
  url          = "https://factory.talos.dev/image/${talos_image_factory_schematic.this.id}/${var.talos_version}/nocloud-amd64-secureboot.iso"
  overwrite    = false
}

output "schematic_id" {
  value = talos_image_factory_schematic.this.id
}

output "installer_image" {
  value       = "factory.talos.dev/installer-secureboot/${talos_image_factory_schematic.this.id}:${var.talos_version}"
  description = "Talos installer image for talosctl upgrade --image"
}
