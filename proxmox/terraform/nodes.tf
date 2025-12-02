# Talos Control Plane Node
resource "proxmox_vm_qemu" "talos_control_01" {
  # VM General Settings
  name        = "talos-control-01"
  target_node = var.proxmox_node
  vmid        = 101
  os_type     = "other"
  iso         = var.talos_iso_path

  # VM System Settings
  agent = 1

  # VM Hardware Settings
  cores   = 4
  sockets = 1
  memory  = 6144
  scsihw  = "virtio-scsi-pci"
  boot    = "order=scsi0;ide2" # Boot from disk first, then CD-ROM (for install)
  disk {
    type    = "scsi"
    storage = "local-lvm"
    size    = "40G"
  }

  # VM Network Settings
  network {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # Talos Machine Configuration (replaces Cloud-Init)
  cloudinit {
    user_data = file("${var.talos_config_path}/controlplane.yaml")
  }
}

# Talos Trusted Worker Node
resource "proxmox_vm_qemu" "talos_worker_trusted" {
  # VM General Settings
  name        = "talos-worker-trusted"
  target_node = var.proxmox_node
  vmid        = 201
  os_type     = "other"
  iso         = var.talos_iso_path

  # VM System Settings
  agent = 1

  # VM Hardware Settings
  cores   = 4
  sockets = 1
  memory  = 10240
  scsihw  = "virtio-scsi-pci"
  boot    = "order=scsi0;ide2"
  disk {
    type    = "scsi"
    storage = "local-lvm"
    size    = "50G"
  }

  # VM Network Settings (Dual NIC)
  network {
    model  = "virtio"
    bridge = "vmbr1"
  }
  network {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # Talos Machine Configuration
  cloudinit {
    user_data = file("${var.talos_config_path}/worker-trusted.yaml")
  }
}

# Talos DMZ Worker Node
resource "proxmox_vm_qemu" "talos_worker_dmz" {
  # VM General Settings
  name        = "talos-worker-dmz"
  target_node = var.proxmox_node
  vmid        = 202
  os_type     = "other"
  iso         = var.talos_iso_path

  # VM System Settings
  agent = 1

  # VM Hardware Settings
  cores   = 4
  sockets = 1
  memory  = 8192
  scsihw  = "virtio-scsi-pci"
  boot    = "order=scsi0;ide2"
  disk {
    type    = "scsi"
    storage = "local-lvm"
    size    = "40G"
  }

  # VM Network Settings (Dual NIC)
  network {
    model  = "virtio"
    bridge = "vmbr2"
  }
  network {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # Talos Machine Configuration
  cloudinit {
    user_data = file("${var.talos_config_path}/worker-dmz.yaml")
  }
}

# Talos Untrusted Worker Node
# Control Plane Node
resource "proxmox_vm_qemu" "control_plane" {
  for_each = { for cp in var.control_plane_nodes : cp.name => cp }

  name        = each.value.name
  target_node = var.proxmox_node

  iso = var.talos_iso_path

  # VM settings
  agent   = 1
  os_type = "cloud-init"
  cores   = each.value.cores
  sockets = 1
  memory  = each.value.memory
  scsihw  = "virtio-scsi-pci"

  disk {
    type    = "scsi"
    storage = "local-lvm"
    size    = each.value.disk_size
  }

  network {
    model   = "virtio"
    bridge  = each.value.bridge
    macaddr = each.value.mac_address
  }

  # Cloud-init settings for Talos
  cloudinit {
    user_data = file("${var.talos_config_path}/controlplane.yaml")
  }
}

# Worker Nodes
resource "proxmox_vm_qemu" "worker" {
  for_each = { for worker in var.worker_nodes : worker.name => worker }

  name        = each.value.name
  target_node = var.proxmox_node

  iso = var.talos_iso_path

  # VM settings
  agent   = 1
  os_type = "cloud-init"
  cores   = each.value.cores
  sockets = 1
  memory  = each.value.memory
  scsihw  = "virtio-scsi-pci"

  disk {
    type    = "scsi"
    storage = "local-lvm"
    size    = each.value.disk_size
  }

  network {
    model   = "virtio"
    bridge  = each.value.bridge
    macaddr = each.value.mac_address
  }

  # Cloud-init settings for Talos
  cloudinit {
    user_data = file("${var.talos_config_path}/worker.yaml")
  }
}
