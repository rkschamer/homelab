variable "proxmox_api_url" {
  type        = string
  description = "The URL for the Proxmox API (e.g., https://192.168.123.2:8006/api2/json)."
}

variable "proxmox_api_token_id" {
  type        = string
  description = "The ID of the Proxmox API token (e.g., root@pam!terraform)."
}

variable "proxmox_api_token_secret" {
  type        = string
  description = "The secret of the Proxmox API token."
  sensitive   = true
}

variable "proxmox_node" {
  type        = string
  description = "The Proxmox node to deploy VMs on."
  default     = "pve" # Change this to your node's name
}

variable "talos_iso_path" {
  type        = string
  description = "The path in Proxmox storage to the Talos installer ISO (e.g., local:iso/talos-amd64.iso)."
}

variable "talos_config_path" {
  type        = string
  description = "The path to the directory containing the Talos machine config files."
  default     = "./talos-config"
}
