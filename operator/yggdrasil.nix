{ config, modulesPath, lib, pkgs, ... }:
{
  # Yggdrasil — the root everything else grows from. An LXC with the kit in
  # /etc/nixos and the tools to rebuild the homelab from nothing; no secrets
  # inside. To administer from here (`ssh root@yggdrasil`, Tailscale SSH):
  #   git clone https://github.com/<you>/yggdrasil-homelab ~/homelab && cd ~/homelab
  #   cp /etc/nixos/site.json .                                   # gitignored, but in the kit
  #   cp /etc/nixos/share/secrets/admin-key.age share/secrets/    # same — or from the NAS kit
  #   mkdir -p ~/.config/sops/age && age -d -o ~/.config/sops/age/keys.txt share/secrets/admin-key.age
  #   python3 bootstrap.py …
  # Both copies matter: a kit built from a clone without them (including this
  # machine's own /etc/nixos after a switch from the clone) would lack them.
  imports = [ "${modulesPath}/virtualisation/proxmox-lxc.nix" ];

  # Proxmox hands over the network (systemd-networkd); the name stays ours
  networking.hostName = "yggdrasil";
  proxmoxLXC.manageHostName = true;

  # Tailscale, joined once by hand: `tailscale up --ssh` in the console prints a
  # login link. Keep `--ssh` there: a bare `tailscale up` resets every pref,
  # turning off the SSH that tailscaled-set enabled at boot. No auth key in the image — the node's identity lives on the CT disk
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
