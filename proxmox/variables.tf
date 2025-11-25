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

variable "template_name" {
  type        = string
  description = "The name of the VM template to clone from."
  default     = "ubuntu-k3s-template"
}
