# Control Plane Nodes
resource "proxmox_vm_qemu" "control_plane" {
  for_each = { for node in var.control_plane_nodes : node.name => node }

  name        = each.value.name
  target_node = var.proxmox_node
  clone       = var.talos_template_name

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

  ipconfig0 = "ip=${each.value.ip_address}/24,gw=${var.gateway}"

  # Cloud-init settings for Talos
  cicustom = "user=${var.talos_config_path}/controlplane.yaml"
}

# Worker Nodes
resource "proxmox_vm_qemu" "worker" {
  for_each = { for worker in var.worker_nodes : worker.name => worker }

  name        = each.value.name
  target_node = var.proxmox_node
  clone       = var.talos_template_name

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

  ipconfig0 = "ip=${each.value.ip_address}/24,gw=${var.gateway}"

  # Cloud-init settings for Talos
  cicustom = "user=${var.talos_config_path}/worker.yaml"
}
