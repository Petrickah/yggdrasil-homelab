# 0. Define the NixOS VMs we want to use. disk_file comes from
# images.auto.tfvars.json — run `bootstrap.py --host <hostname> image` first.
module "alfheim" {
  source    = "./.modules"
  node_name = local.proxmox_node
  hostname  = "alfheim"
  vm_id     = 202
  cores     = 2
  memory    = 4096
  disk_size = 128
  disk_file = lookup(var.images, "alfheim", "")
}

module "nidavellir" {
  source    = "./.modules"
  node_name = local.proxmox_node
  hostname  = "nidavellir"
  vm_id     = 201
  cores     = 2
  memory    = 4096
  disk_size = 128
  disk_file = lookup(var.images, "nidavellir", "")
}

module "mimisbrunnr" {
  source    = "./.modules"
  node_name = local.proxmox_node
  hostname  = "mimisbrunnr"
  vm_id     = 200
  cores     = 2
  memory    = 4096
  disk_size = 128
  disk_file = lookup(var.images, "mimisbrunnr", "")
}

# Parked with hosts/_parked/asgard.nix while the original Proxmox VE stays in
# use — move both back to bring asgard (NixOS-based Proxmox) into the build.
# module "asgard" {
#   source    = "./.modules"
#   node_name = local.proxmox_node
#   hostname  = "asgard"
#   vm_id     = 203
#   cores     = 4
#   memory    = 8192
#   disk_size = 512
#   disk_file = lookup(var.images, "asgard", "")
# }
