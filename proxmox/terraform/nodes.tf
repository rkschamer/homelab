# Talos Control Plane Node
resource "proxmox_virtual_environment_vm" "control_plane" {
  name        = "talos-control-plane-1"
  description = "Managed by Terraform"
  tags        = ["terraform", "talos", "control-plane"]
  node_name   = var.proxmox_node
  vm_id       = var.control_plane_vmid
  on_boot     = true

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
  }

  agent {
    enabled = true
  }

  # Management Network (192.168.123.0/24)
  network_device {
    bridge = "vmbr0"
  }

  # Trusted Network (10.10.20.0/24)
  network_device {
    bridge = "vmbr1"
  }

  # DMZ Network (10.10.30.0/24)
  network_device {
    bridge = "vmbr2"
  }

  # Untrusted Network (10.10.40.0/24)
  network_device {
    bridge = "vmbr3"
  }

  # Monitoring Network (10.10.50.0/24)
  network_device {
    bridge = "vmbr4"
  }

  cdrom {
    file_id = proxmox_virtual_environment_download_file.talos_iso.id
  }

  disk {
    datastore_id = "local-zfs"
    interface    = "virtio0"
    size         = 32
  }

  operating_system {
    type = "l26" # Linux Kernel 2.6 - 5.X
  }

  lifecycle {
    ignore_changes = [cdrom]
  }

  # Talos doesn't use cloud-init - IP configuration is in Talos YAML files
}

# Talos Worker Nodes
resource "proxmox_virtual_environment_vm" "workers" {
  for_each = { for node in var.worker_nodes : node.name => node }

  name        = each.value.name
  description = "Managed by Terraform"
  tags        = ["terraform", "talos", "worker", each.value.network_zone]
  node_name   = var.proxmox_node
  vm_id       = each.value.vmid
  on_boot     = true

  cpu {
    cores = each.value.cores
    # this would allow VM hotplug, which is currently not needed
    #type  = "x86-64-v2-AES"
    type = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  agent {
    enabled = true
  }

  # Temporary management network for initial configuration
  network_device {
    bridge = "vmbr0"
  }

  # Production network (isolated)
  network_device {
    bridge = each.value.network_bridge
  }

  cdrom {
    file_id = proxmox_virtual_environment_download_file.talos_iso.id
  }

  disk {
    datastore_id = "local-zfs"
    interface    = "virtio0"
    size         = each.value.disk_size_gb
  }

  operating_system {
    type = "l26" # Linux Kernel 2.6 - 5.X
  }

  # ignore changes to cdrom to prevent reinstallation on config updates
  # otherwise, an update in Talos version would reset the CD-ROM drive
  lifecycle {
    ignore_changes = [cdrom]
  }
}
