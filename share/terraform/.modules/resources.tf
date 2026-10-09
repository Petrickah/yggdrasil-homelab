# Create the NixOS VM
resource "proxmox_virtual_environment_vm" "nixos" {
  description     = file("${path.module}/../../docs/${var.hostname}.html")
  node_name       = var.node_name
  vm_id           = var.vm_id
  name            = var.hostname
  stop_on_destroy = true

  agent {
    enabled = false
  }

  bios = "ovmf"

  efi_disk {
    datastore_id      = "local-zfs"
    file_format       = "raw"
    type              = "4m"
    pre_enrolled_keys = false
  }

  cpu {
    cores        = var.cores # Allocating multiple cores speeds up package building
    type         = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.memory # 4 GB RAM prevents the OOM Killer from stopping the build
    floating  = var.memory # Enable balloning
  }

  disk {
    # local-zfs is zvol-backed — the resulting disk is always raw regardless
    # of what's declared here; qcow2 is only the *source* file's own format
    # (import_from), which Proxmox converts on import. Declaring "raw" here
    # matches what Proxmox actually reports back, so `plan` converges.
    file_format  = "raw"
    interface    = "virtio0"
    datastore_id = "local-zfs"
    import_from  = "local:import/${var.disk_file}"
    size         = var.disk_size
  }

  # The image is only how a VM is born; after that it's updated in place with
  # `bootstrap.py switch`. Without this, every new image would destroy and
  # recreate the VM — and its /var/lib/services data with it.
  lifecycle {
    ignore_changes = [disk[0].import_from]
  }

  network_device {
    bridge = "vmbr0"
  }

  operating_system {
    type = "l26"
  }
}

