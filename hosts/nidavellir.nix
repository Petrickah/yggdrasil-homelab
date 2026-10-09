{ config, lib, pkgs, site, ... }:
{
  imports = [ ../share/services/vaultwarden ];

  # Identity and static networking — no cloud-init involved, everything below
  # is baked into this host's own image at build time.
  homelab.heimdall.enable = true;
  homelab.heimdall.settings = {
    hostName = "nidavellir";    # unique hostname identifier
    hostId   = "49500df1";      # required by ZFS support in the kernel
    address  = site.hosts.nidavellir.address;  # the IP Address, from site.json
  };

  homelab.bifrost.enable = true;
  homelab.bifrost = {
    # Users authorized on this container (username -> SSH public key)
    users.sindri = site.sshKey;
  };

  # Small tools for poking around the VM
  environment.systemPackages = with pkgs; [ htop ];

  # Use the latest NixOS version
  system.stateVersion = "26.05";
}
