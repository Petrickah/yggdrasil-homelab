{ config, lib, pkgs, ... }:
{
  # Data in /var/lib/services/qdrant, copied once by `bootstrap.py seed` —
  # stop the live container (or use a qdrant snapshot) first.
  homelab.services.qdrant = { };

  # Configure Docker Container for qDrant
  virtualisation.docker.enable = true;
  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.qdrant = {
    image = "qdrant/qdrant:v1.18.2";
    volumes = [ "/var/lib/services/qdrant:/qdrant/storage" ];
    ports = [ "127.0.0.1:6333:6333" "127.0.0.1:6334:6334" ];
    # API key decrypted by sops-nix at boot from share/secrets/<hostname>.yaml.
    environmentFiles = [ config.sops.secrets.qdrant_env.path ];
  };

  # Reached only through Tailscale Serve: REST over HTTPS, gRPC as raw TCP.
  # (Bound to 127.0.0.1 — a port Docker publishes on 0.0.0.0 bypasses the
  # NixOS firewall; until 2026-10-10 this one answered on the LAN.)
  homelab.heimdall.serve."6333" = "http://127.0.0.1:6333";
  homelab.heimdall.serve."tcp:6334" = "tcp://127.0.0.1:6334";

  sops.secrets.qdrant_env = { };
}
