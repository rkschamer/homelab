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

variable "talos_template_name" {
  type        = string
  description = "The name of the Talos VM template to clone."
}

variable "talos_config_path" {
  type        = string
  description = "The path to the directory containing the Talos machine config files."
  default     = "../homelab-cluster/talos"
}

variable "nodes" {
  description = "A list of all node configurations (control plane and workers)."
  type = list(object({
    name           = string
    node_type      = string # "control_plane" or "worker"
    ip_address     = string
    disk_size      = string
    memory         = number
    cores          = number
    network_bridge = string
    gateway        = string
    config_file    = string
  }))
  default = []
}
