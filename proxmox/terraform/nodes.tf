# Talos Cluster Nodes (Control Plane + Workers)
resource "proxmox_vm_qemu" "nodes" {
  for_each = { for node in var.nodes : node.name => node }

  name        = each.value.name
  target_node = var.proxmox_node
  clone       = var.talos_template_name
  vmid        = each.value.vm_id

  # Full clone is required for independent VMs
  full_clone = true

  # VM settings - Talos doesn't run QEMU guest agent by default
  agent              = 0
  memory             = each.value.memory
  start_at_node_boot = true

  cpu {
    sockets = 1
    cores   = each.value.cores
  }

  # Disk configuration
  disks {
    scsi {
      scsi0 {
        disk {
          storage = "local-zfs"
          size    = each.value.disk_size
        }
      }
    }
  }

  # Network configuration with static IP
  network {
    id     = 0
    model  = "virtio"
    bridge = each.value.network_bridge
  }

  # Static IP configuration
  ipconfig0 = "ip=${each.value.ip_address}/24,gw=${each.value.gateway}"

  # Increase timeouts for VM operations
  timeouts {
    create = "10m"
    update = "5m"
    delete = "5m"
  }
}
