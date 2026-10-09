{ config, lib, pkgs, ... }:
{
  # Initial data, copied once into /var/lib/services/qdrant on first boot.
  # Only present in the archive of the host that runs qdrant, so null elsewhere.
  # Stop the live container (or use a qdrant snapshot) before building a
  # template you intend to keep — ./data is copied as-is.
  homelab.services.qdrant.seed = if builtins.pathExists ./data then ./data else null;

  # Configure Docker Container for qDrant
  virtualisation.docker.enable = true;
  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.qdrant = {
    image = "qdrant/qdrant:v1.18.2";
    volumes = [ "/var/lib/services/qdrant:/qdrant/storage" ];
    ports = [ "6333:6333" "6334:6334" ];
    # The firewall (heimdall.nix) already restricts inbound to tailscale0, so
    # binding wide here is fine, unlike the 127.0.0.1-only + Tailscale Serve
    # setup on the old Debian host. API key decrypted by sops-nix at boot from
    # share/secrets/<hostname>.yaml.
    environmentFiles = [ config.sops.secrets.qdrant_env.path ];
  };

  sops.secrets.qdrant_env = { };
}
