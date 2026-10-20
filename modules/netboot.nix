{ config, lib, pkgs, site, ... }:
let
  # TFTP is served by the netboot.xyz container on this same host
  tftpServer = site.hosts.alfheim.address;

  # ProxyDHCP range = this host's /24, derived from site.json (kept out of git)
  subnet = lib.concatStringsSep "." (lib.take 3 (lib.splitString "." tftpServer) ++ [ "0" ]);
in
{
  assertions = [{
    assertion = site.network.prefixLength == 24;
    message   = "netboot.nix: the ProxyDHCP range assumes a /24 network";
  }];

  # 1. Enable ProxyDHCP with dnsmasq
  # ProxyDHCP only: no DNS, no TFTP. Clients are pointed at the container's
  # TFTP (root /config/menus), whose bootloaders then load local-vars.ipxe
  # and menu.ipxe from that same server instead of boot.netboot.xyz.
  services.dnsmasq.enable = true;
  services.dnsmasq.resolveLocalQueries = false;
  services.dnsmasq.settings = {
    port            = 0;
    interface       = config.homelab.heimdall.settings.interface;
    bind-interfaces = true;
    dhcp-range      = [ "${subnet},proxy,255.255.255.0" ];
    pxe-prompt      = [ "\"netboot.xyz\",0" ];
    # The 4th field is the TFTP server; without it dnsmasq points at itself.
    # UEFI goes through the signed shim -> plain iPXE -> autoexec.ipxe (all in
    # secureboot-x86_64/, autoexec.ipxe is ours): netboot.xyz.efi's embedded
    # script looks for local-vars.ipxe on the router's next-server first and,
    # with no TFTP there, falls back to the online menu. Works with Secure
    # Boot on too (signed kernels only). BIOS still needs "p" at the prompt.
    pxe-service     = [
      "x86PC,\"netboot.xyz BIOS\",netboot.xyz.kpxe,${tftpServer}"
      "x86-64_EFI,\"netboot.xyz UEFI\",secureboot-x86_64/shimx64.efi,${tftpServer}"
      "BC_EFI,\"netboot.xyz UEFI\",secureboot-x86_64/shimx64.efi,${tftpServer}"
    ];
    log-dhcp = true;  # shows in journalctl -u dnsmasq what each client requests
  };

  # 2. We need to allow local traffic on the ports for ProxyDHCP
  # 67 (DHCP Proxy), 4011 (ProxyDHCP Listening). TFTP (69) and HTTP (8080)
  # are published by Docker, which bypasses the NixOS firewall anyway.
  networking.firewall.allowedUDPPorts = [ 67 4011 ];

  # Enable Docker for NixOS OCI Containers
  virtualisation.oci-containers.backend = "docker";

  # Define the official netboot.xyz container
  virtualisation.oci-containers.containers."pxeboot" = {
    image = "ghcr.io/netbootxyz/netbootxyz:latest";
    ports = [
      # LAN-facing on purpose: PXE clients have no Tailscale
      "69:69/udp" # TFTP: bootloaders and menus from /config/menus
      "8080:80"   # Local HTTP port where PXE clients downloads images from
      "127.0.0.1:3000:3000" # Web interface port for administration
    ];
    environment = {
      SUBFOLDER = "/";
      # Match the owner the Synology maps every NFS file to (1024:users), so
      # the container's TFTP (secure mode: serves only files owned by its user)
      # can read what's on the share
      PUID = "1024";
      PGID = "100";
    };
    volumes = [
      # ISO/VHDX are downloaded over to the NAS
      "/mnt/syno-nfs/tftpboot/config:/config"
      "/mnt/syno-nfs/tftpboot/assets:/assets"
    ];
  };

  # Wait until the NFS Share is mount, then boot the container.
  systemd.services.docker-pxeboot.unitConfig.RequiresMountsFor = [ "/mnt/syno-nfs/tftpboot" ];

  # Deschiere porturi în firewall pentru interfața web și serverul web local de imagini
  homelab.heimdall.serve."3000" = "http://127.0.0.1:3000";
}
