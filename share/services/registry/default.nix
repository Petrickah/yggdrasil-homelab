{ config, lib, pkgs, ... }:
{
  # Starts empty on purpose: images are build artifacts, Jenkins makes them
  # again. Data in /var/lib/services/registry, created by Docker on first start.
  virtualisation.docker.enable = true;
  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.registry = {
    image = "registry:2";
    volumes = [
      "/var/lib/services/registry:/var/lib/registry"
      "${config.sops.secrets.registry_htpasswd.path}:/auth/htpasswd:ro"
    ];
    ports = [ "127.0.0.1:5000:5000" ];   # only Tailscale Serve reaches it
    environment = {
      REGISTRY_AUTH                  = "htpasswd";
      REGISTRY_AUTH_HTPASSWD_PATH    = "/auth/htpasswd";
      REGISTRY_AUTH_HTPASSWD_REALM   = "Registry Realm";
      REGISTRY_STORAGE_DELETE_ENABLED = "true";
    };
  };

  homelab.heimdall.serve."5000" = "http://127.0.0.1:5000";

  # `registrar:<bcrypt>` — the same password as the console, written by
  # `bootstrap.py rotate console-password` (one password to know, not one per system)
  sops.secrets.registry_htpasswd.sopsFile = ../../secrets/common.yaml;
}
