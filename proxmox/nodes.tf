# k3s Control Plane Node
resource "proxmox_vm_qemu" "k3s_control_01" {
  # VM General Settings
  name        = "k3s-control-01"
  target_node = var.proxmox_node
  clone       = var.template_name
  vmid        = 101

  # VM System Settings
  agent = 1

  # VM Hardware Settings
  cores   = 4
  sockets = 1
  memory  = 6144
  scsihw  = "virtio-scsi-pci"
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

  # Cloud-Init Settings
  ipconfig0  = "ip=192.168.123.10/24,gw=192.168.123.1"
  nameserver = "192.168.123.1"
}

# k3s Trusted Worker Node
resource "proxmox_vm_qemu" "k3s_worker_trusted" {
  # VM General Settings
  name        = "k3s-worker-trusted"
  target_node = var.proxmox_node
  clone       = var.template_name
  vmid        = 201

  # VM System Settings
  agent = 1

  # VM Hardware Settings
  cores   = 4
  sockets = 1
  memory  = 10240
  scsihw  = "virtio-scsi-pci"
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

  # Cloud-Init Settings
  ipconfig0  = "ip=10.10.20.11/24,gw=10.10.20.1"
  ipconfig1  = "ip=192.168.123.21/24"
  nameserver = "192.168.123.1"
}

# k3s DMZ Worker Node
resource "proxmox_vm_qemu" "k3s_worker_dmz" {
  # VM General Settings
  name        = "k3s-worker-dmz"
  target_node = var.proxmox_node
  clone       = var.template_name
  vmid        = 202

  # VM System Settings
  agent = 1

  # VM Hardware Settings
  cores   = 4
  sockets = 1
  memory  = 8192
  scsihw  = "virtio-scsi-pci"
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

  # Cloud-Init Settings
  ipconfig0  = "ip=10.10.30.10/24,gw=10.10.30.1"
  ipconfig1  = "ip=192.168.123.22/24"
  nameserver = "192.168.123.1"
}

# k3s Untrusted Worker Node
resource "proxmox_vm_qemu" "k3s_worker_untrusted" {
  # VM General Settings
  name        = "k3s-worker-untrusted"
  target_node = var.proxmox_node
  clone       = var.template_name
  vmid        = 203

  # VM System Settings
  agent = 1

  # VM Hardware Settings
  cores   = 2
  sockets = 1
  memory  = 4096
  scsihw  = "virtio-scsi-pci"
  disk {
    type    = "scsi"
    storage = "local-lvm"
    size    = "32G"
  }

  # VM Network Settings (Dual NIC)
  network {
    model  = "virtio"
    bridge = "vmbr3"
  }
  network {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # Cloud-Init Settings
  ipconfig0  = "ip=10.10.40.10/24,gw=10.10.40.1"
  ipconfig1  = "ip=192.168.123.23/24"
  nameserver = "192.168.123.1"
}
