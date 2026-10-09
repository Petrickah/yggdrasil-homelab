terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.113.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1"
    }
  }
}

# Everything specific to this installation (addresses, Proxmox host) comes
# from the repository's site.json, shared with Nix and bootstrap.py.
locals {
  site         = jsondecode(file("${path.module}/../../site.json"))
  proxmox_host = coalesce(var.proxmox_host, local.site.proxmox.host)
  proxmox_node = coalesce(var.proxmox_node, local.site.proxmox.node)
}

# Every credential comes from the sops-encrypted terraform.yaml. Decrypting it
# needs the admin age key (~/.config/sops/age/keys.txt, or SOPS_AGE_KEY_FILE).
data "sops_file" "terraform" {
  source_file = "${path.module}/../secrets/terraform.yaml"
}

provider "proxmox" {
  endpoint  = "https://${local.proxmox_host}:8006/"
  api_token = data.sops_file.terraform.data["proxmox_api_token"]
  insecure  = true # Set to false if using valid TLS certificates

  ssh {
    agent       = false
    username    = "root"
    private_key = data.sops_file.terraform.data["proxmox_ssh_key"]
    node {
      name    = local.proxmox_node
      address = local.proxmox_host
    }
  }
}
