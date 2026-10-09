{ config, lib, pkgs, site, ... }:
{
  # Identity and static networking — no cloud-init involved, everything below
  # is baked into this host's own image at build time.
  homelab.heimdall.enable = true;
  homelab.heimdall.settings = {
    hostName = "alfheim";       # unique hostname identifier
    hostId   = "f176a204";      # required by ZFS support in the kernel
    address  = site.hosts.alfheim.address;  # the IP Address, from site.json
  };

  homelab.bifrost.enable = true;
  homelab.bifrost = {
    # Users authorized on this container (username -> SSH public key)
    users.freyr = site.sshKey;
  };

  # Use the latest NixOS version
  system.stateVersion = "26.05";
}
