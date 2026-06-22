# Talos Control Plane Nodes
resource "proxmox_virtual_environment_vm" "control_plane" {
  for_each = { for node in var.control_plane : node.name => node }

  name        = each.value.name
  description = "Managed by Terraform"
  tags        = ["terraform", "talos", "control-plane"]
  node_name   = var.proxmox_node
  vm_id       = each.value.vmid
  on_boot     = true

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  agent {
    enabled = true
  }

  # UEFI with SecureBoot
  # pre_enrolled_keys = false allows Talos to auto-enroll its own Secure Boot keys
  bios = "ovmf"
  machine = "q35"

  efi_disk {
    datastore_id      = "local-lvm"
    pre_enrolled_keys = false
    type              = "4m"
  }

  tpm_state {
    datastore_id = "local-lvm"
    version      = "v2.0"
  }

  # Network devices from configuration
  dynamic "network_device" {
    for_each = each.value.network_devices
    content {
      bridge      = network_device.value.bridge
      mac_address = network_device.value.mac_address
    }
  }

  cdrom {
    file_id = proxmox_download_file.talos_iso.id
  }

  # System disk
  disk {
    datastore_id = "local-lvm"
    interface    = "virtio0"
    size         = each.value.disks.system_size_in_gb
    discard      = "on"
    backup       = false
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
  tags        = ["terraform", "talos", "worker"]
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
    # they're isolated to workload networks, which are not reachable by the management network
    # since terraform would wait for an IP for 15m (default), we set a relatively short timeout
    timeout = "10s"
  }

  # UEFI with SecureBoot
  # pre_enrolled_keys = false allows Talos to auto-enroll its own Secure Boot keys
  bios = "ovmf"
  machine = "q35"

  efi_disk {
    datastore_id      = "local-lvm"
    pre_enrolled_keys = false
    type              = "4m"
  }

  tpm_state {
    datastore_id = "local-lvm"
    version      = "v2.0"
  }

  # Cloud-init network configuration
  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "${each.value.ip_address}/24"
        gateway = each.value.gateway
      }
    }
  }

  # Production networks only - workers isolated to their designated networks
  dynamic "network_device" {
    for_each = each.value.network_devices
    content {
      bridge      = network_device.value.bridge
      mac_address = network_device.value.mac_address
    }
  }

  cdrom {
    file_id = proxmox_download_file.talos_iso.id
  }

  # System disk
  disk {
    datastore_id = "local-lvm"
    interface    = "virtio0"
    size         = each.value.disks.system_size_in_gb
    discard      = "on"
    backup       = false
  }

  # User volume disk (for Longhorn CSI)
  disk {
    datastore_id = "local-lvm"
    interface    = "virtio2"
    size         = each.value.disks.user_size_in_gb
    discard      = "on"
    backup       = false # Longhorn handles replication
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
