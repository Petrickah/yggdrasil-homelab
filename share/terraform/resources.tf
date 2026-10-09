resource "proxmox_storage_nfs" "syno-nfs" {
  id     = "syno-nfs"
  nodes  = [local.proxmox_node]
  server = local.site.nas.address
  export = local.site.nas.export

  content = ["backup", "import", "vztmpl", "snippets"]

  options                  = "vers=4.1"
  preallocation            = "metadata"
  snapshot_as_volume_chain = true

  backups {
    max_protected_backups = 5
    keep_daily            = 7
  }
}

resource "proxmox_virtual_environment_certificate" "pveprox-ssl" {
  node_name   = local.proxmox_node
  certificate = data.sops_file.terraform.data["pveproxy_pem"]
  private_key = data.sops_file.terraform.data["pveproxy_key"]
}