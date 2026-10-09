{ modulesPath, lib, pkgs, ... }:
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

  # Nothing comes in: you work from the Proxmox console (`pct enter`)
  services.openssh.enable = false;

  environment.systemPackages = with pkgs; [ git zstd ];

  # Use the latest NixOS version
  system.stateVersion = "26.05";
}
