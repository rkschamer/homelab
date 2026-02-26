variable "proxmox_api_url" {
  type        = string
  description = "The URL for the Proxmox API (e.g., https://192.168.123.8:8006/api2/json)."
}

variable "proxmox_api_token_id" {
  type        = string
  description = "The ID of the Proxmox API token (e.g., root@pam!terraform)."
  sensitive   = true
}

variable "proxmox_api_token_secret" {
  type        = string
  description = "The secret of the Proxmox API token."
  sensitive   = true
}

variable "proxmox_node" {
  type        = string
  description = "The Proxmox node to deploy VMs on."
  default     = "proxmox" # Change this to your node's name
}

variable "talos_version" {
  type        = string
  description = "The version of Talos to deploy."
  default     = "v1.11.6"

}

variable "cluster_name" {
  type        = string
  description = "The name of the Talos cluster."
  default     = "homelab"
}

variable "control_plane" {
  description = "List of control plane node configurations."
  type = list(object({
    name       = string
    vmid       = number
    ip_address = string
    disks = object({
      system_size_in_gb = number
      swap_size_in_gb   = number
    })
    memory = number
    cores  = number
    network_devices = list(object({
      bridge      = string
      mac_address = string
    }))
    gateway       = string
    subnet_prefix = number
  }))
}

variable "worker_nodes" {
  description = "List of worker node configurations."
  type = list(object({
    name = string
    vmid = number
    disks = object({
      system_size_in_gb = number
      swap_size_in_gb   = number
      user_size_in_gb   = number
    })
    memory = number
    cores  = number
    network_devices = list(object({
      bridge      = string
      mac_address = string
    }))
    network_zone  = string
    gateway       = string
    subnet_prefix = number
  }))
  default = []
}
