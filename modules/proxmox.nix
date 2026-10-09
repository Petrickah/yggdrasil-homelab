{ modulesPath, config, pkgs, lib, site, ... }:
{
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];

  # systemd-boot on an ESP that mk-qcow2.sh fills from the template's /boot;
  # later switches update it normally.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;

  # mk-qcow2.sh creates a small disk; Proxmox resizes it on import and the
  # root partition + filesystem grow into the extra space on boot.
  boot.growPartition = true;

  # The labels are read by template.nix and baked into mk-qcow2.sh
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  fileSystems."/" = {
    device     = "/dev/disk/by-label/nixos";
    fsType     = "ext4";
    options    = [ "noatime" ];
    autoResize = true;
  };

  # Same NFS export Proxmox already mounts at /mnt/pve/syno-nfs — mounted here
  # directly by the guest so the restore script below doesn't need to go
  # through Proxmox as an intermediary at all.
  fileSystems."/mnt/syno-nfs" = {
    device  = "${site.nas.address}:${site.nas.export}";
    fsType  = "nfs";
    options = [ "nofail" "x-systemd.automount" "x-systemd.device-timeout=10s" ];
  };
}
