{ config, pkgs, lib, site, ... }:
let
  cfg = config.homelab.heimdall;
in
{
  options.homelab.heimdall = {
    enable = lib.options.mkEnableOption "Enable the firewall for configuration";
    settings = {
      interface = lib.options.mkOption {
        description = "The Interface of the VM";
        type = lib.types.str;
        default = "ens18";
      };
      hostName  = lib.options.mkOption {
        description = "The Hostname of the VM";
        type = lib.types.str;
      };
      hostId = lib.options.mkOption {
        description = "Unique host ID required by ZFS support in the kernel";
        type = lib.types.str;
      };
      address = lib.options.mkOption {
        description = "The IP Address for this VM";
        type = lib.types.str;
      };
      authKeyFile = lib.options.mkOption {
        # A runtime path (string), never a Nix path: a Nix path would copy the
        # key into the world-readable store. Decrypted by sops-nix at boot.
        description = "The AuthKey file for Tailscale";
        default = config.sops.secrets.tailscale_key.path;
        defaultText = lib.literalExpression "config.sops.secrets.tailscale_key.path";
        type = lib.types.str;
      };
    };

    serve = lib.options.mkOption {
      description = ''
        Tailscale Serve on this host: port -> local target. Services listen on
        127.0.0.1 only and are reached solely through here — a port Docker
        publishes on 0.0.0.0 bypasses the NixOS firewall and shows up on the LAN.
        A plain port is HTTPS (with a tailnet certificate); prefix it with
        `tcp:` for raw TCP, e.g. SSH.
      '';
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "8122" = "http://127.0.0.1:8122";
        "tcp:2222" = "tcp://127.0.0.1:2222";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Tailscale Serve, declarative: reset, then exactly what cfg.serve lists
    systemd.services.homelab-tailscale-serve = lib.mkIf (cfg.serve != { }) {
      description = "Tailscale Serve for this host's services";
      after       = [ "tailscaled.service" "tailscaled-autoconnect.service" ];
      wants       = [ "tailscaled.service" ];
      wantedBy    = [ "multi-user.target" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = let
        tailscale = lib.getExe config.services.tailscale.package;
        serveOne  = port: target:
          if lib.hasPrefix "tcp:" port
          then "${tailscale} serve --bg --tcp=${lib.removePrefix "tcp:" port} ${target}"
          else "${tailscale} serve --bg --https=${port} ${target}";
      in ''
        ${tailscale} serve reset
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList serveOne cfg.serve)}
      '';
    };

    # Enable the Tailscale service and authenticate via an AuthKey
    sops.secrets.tailscale_key.sopsFile = ../share/secrets/common.yaml;
    services.tailscale.enable = true;
    services.tailscale.authKeyFile = cfg.settings.authKeyFile;

    # Setting up the host network options
    networking.useDHCP  = false;
    networking.hostName = cfg.settings.hostName;
    networking.hostId   = cfg.settings.hostId;
    networking.interfaces.${cfg.settings.interface}.ipv4.addresses = [{
      address      = cfg.settings.address;
      prefixLength = site.network.prefixLength;
    }];
    networking.defaultGateway = site.network.gateway;
    networking.nameservers    = site.network.nameservers;

    # Force tailscaled to use nftables (Critical for clean nftables-only systems)
    # This avoids the "iptables-compat" translation layer issues.
    networking.nftables.enable = true;

    # Enable the firewall
    networking.firewall.enable = true;
    networking.firewall = {
      # Always allow traffic from your Tailscale network
      trustedInterfaces = [ config.services.tailscale.interfaceName ];

      # Always block traffic from your Local network 
      allowedTCPPorts = [ ];

      # Allow the Tailscale UDP port through the firewall
      allowedUDPPorts = [ config.services.tailscale.port ];
    };

    # Optimization: Prevent systemd from waiting for network online
    systemd.network.wait-online.enable = false;
    systemd.services.tailscaled.serviceConfig.Environment = [ 
      "TS_DEBUG_FIREWALL_MODE=nftables" 
    ];

    # Cache DNS lookups to improve performance
    services.resolved.enable = true;
    services.resolved.settings = {
      Resolve.Cache=true;
      Resolve.CacheFromLocalhost=true;
    };
  };
}