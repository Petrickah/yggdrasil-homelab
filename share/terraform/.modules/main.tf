# The provider itself is configured once, in ../main.tf — a child module only
# declares which provider it needs.
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.113.0"
    }
  }
}
