{ config, lib, pkgs, ... }:
{
  # Data in /var/lib/services/vaultwarden, copied once by `bootstrap.py seed` —
  # stop the old container first, SQLite's -wal/-shm files must be consistent.
  homelab.services.vaultwarden = { };

  virtualisation.docker.enable = true;
  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.vaultwarden = {
    image = "vaultwarden/server:1.37.2";
    volumes = [ "/var/lib/services/vaultwarden:/data" ];
    ports = [ "127.0.0.1:8122:8080" ];   # only Tailscale Serve reaches it
    environment = {
      ROCKET_PORT = "8080";
      ROCKET_ADDRESS = "0.0.0.0";
      SIGNUPS_ALLOWED = "false";
      LOG_FILE = "/data/log/my.log";
    };
    environmentFiles = [ config.sops.secrets.vaultwarden_env.path ];
  };

  # HTTPS through Tailscale Serve, same port as on the old host
  homelab.heimdall.serve."8122" = "http://127.0.0.1:8122";

  sops.secrets.vaultwarden_env = { };
}
