variable "proxmox_host" {
  type        = string
  description = "Address of the Proxmox host Terraform and SSH talk to (default: site.json)"
  default     = null
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name the VMs are created on (default: site.json)"
  default     = null
}

variable "images" {
  type        = map(string)
  description = "hostname -> qcow2 file in local:import, written by `bootstrap.py image` into images.auto.tfvars.json"
  default     = {}
}
