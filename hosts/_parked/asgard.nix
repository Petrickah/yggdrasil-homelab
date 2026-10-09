{ config, lib, pkgs, site, ... }:
{
  # Identity and static networking — no cloud-init involved, everything below
  # is baked into this host's own image at build time.
  homelab.heimdall.enable = true;
  homelab.heimdall.settings = {
    interface = "vmbr0";         # the virtual bridge for Proxmox VE
    hostName  = "asgard";        # unique hostname identifier
    hostId    = "a1d1bab8";      # required by ZFS support in the kernel
    address   = site.hosts.asgard.address;  # the IP Address, from site.json
  };

  homelab.bifrost.enable = true;
  homelab.bifrost = {
    # Users authorized on this container (username -> SSH public key)
    users.odin = site.sshKey;
  };

  services.proxmox-ve = {
    enable = true;
    ipAddress = site.hosts.asgard.address;
  };

  # Make vmbr0 bridge visible in Proxmox web interface
  services.proxmox-ve.bridges = [ "vmbr0" ];

  # Actually set up the vmbr0 bridge
  networking.bridges.vmbr0.interfaces = [ "ens18" ];
  networking.interfaces.vmbr0.useDHCP = lib.mkDefault true;

  # Use the latest NixOS version
  system.stateVersion = "26.05";
}