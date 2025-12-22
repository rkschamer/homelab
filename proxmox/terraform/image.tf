data "talos_image_factory_extensions_versions" "this" {
  talos_version = var.talos_version
  filters = {
    names = [
      "siderolabs/amd-ucode",
      "siderolabs/amdgpu",
      "siderolabs/qemu-guest-agent"
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

resource "proxmox_virtual_environment_download_file" "talos_metal_image" {
  depends_on                  = [talos_image_factory_schematic.this]
  content_type            = "iso"
  datastore_id            = "local"
  node_name               = var.proxmox_node

  file_name               = "talos-${var.talos_version}-metal-amd64.img"
  url                     = "https://factory.talos.dev/image/${talos_image_factory_schematic.this.id}/${var.talos_version}/metal-amd64.raw.zst"
  decompression_algorithm = "zst"
  overwrite               = false
}

output "schematic_id" {
  value = talos_image_factory_schematic.this.id
}
