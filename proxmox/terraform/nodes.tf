# Talos Cluster Nodes (Control Plane + Workers)
resource "proxmox_vm_qemu" "nodes" {
  for_each = { for node in var.nodes : node.name => node }

  name        = each.value.name
  target_node = var.proxmox_node
  clone       = var.talos_template_name
  vmid        = each.value.vm_id

  # VM settings
  agent   = 1
  os_type = "cloud-init"
  memory  = each.value.memory

  cpu {
    sockets = 1
    cores   = each.value.cores
  }

  disk {
    slot    = "scsi0"
    storage = "local-lvm"
    size    = each.value.disk_size
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = each.value.network_bridge
  }

  ipconfig0 = "ip=${each.value.ip_address}/24,gw=${each.value.gateway}"

  # Cloud-init settings for Talos
  cicustom = "user=${var.talos_config_path}/${each.value.config_file}"
}
