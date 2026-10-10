{ config, modulesPath, lib, pkgs, ... }:
{
  # Yggdrasil — the root everything else grows from. An LXC with the kit in
  # /etc/nixos and the tools to rebuild the homelab from nothing; no secrets
  # inside. After `pct enter <id>`, bring the admin key out of the kit:
  #   mkdir -p ~/.config/sops/age
  #   age -d -o ~/.config/sops/age/keys.txt /etc/nixos/share/secrets/admin-key.age
  #   cp -r /etc/nixos ~/homelab && chmod -R u+w ~/homelab && cd ~/homelab
  #   python3 bootstrap.py --proxmox <proxmox-ip> …
  imports = [ "${modulesPath}/virtualisation/proxmox-lxc.nix" ];

  # Proxmox hands over the network (systemd-networkd); the name stays ours
  networking.hostName = "yggdrasil";
  proxmoxLXC.manageHostName = true;

  # Tailscale, joined once by hand: `tailscale up` in the console prints a login
  # link. No auth key in the image — the node's identity lives on the CT disk
  # and in its backups. Needs /dev/net/tun passed into the CT (`create` does it).
  services.tailscale.enable = true;

  # Tailscale SSH: get in from any of your devices with your tailnet identity —
  # no SSH keys, no password, so no OpenSSH server either
  services.tailscale.extraSetFlags = [ "--ssh" ];
  services.openssh.enable = false;

  # Only the tailnet gets in; the LAN sees nothing
  networking.firewall.enable = true;
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.allowedUDPPorts = [ config.services.tailscale.port ];

  # The console logs straight in as root. Reaching it already takes a Proxmox
  # login, and anyone with that can `pct enter` as root anyway — a password
  # here would protect against no one, and would be one more secret to rotate.
  services.getty.autologinUser = "root";

  environment.systemPackages = with pkgs; [ git zstd ];

  # Use the latest NixOS version
  system.stateVersion = "26.05";
}
