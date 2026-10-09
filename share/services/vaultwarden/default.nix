{ config, lib, pkgs, ... }:
{
  # Initial data, copied once into /var/lib/services/vaultwarden.
  # Stop the old container before building — SQLite's -wal/-shm files must be consistent.
  homelab.services.vaultwarden.seed = if builtins.pathExists ./data then ./data else null;

  virtualisation.docker.enable = true;
  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.vaultwarden = {
    image = "vaultwarden/server:1.37.2";
    volumes = [ "/var/lib/services/vaultwarden:/data" ];
    ports = [ "127.0.0.1:8122:8080" ];   # only Tailscale Serve reaches it (step 5)
    environment = {
      ROCKET_PORT = "8080";
      ROCKET_ADDRESS = "0.0.0.0";
      SIGNUPS_ALLOWED = "false";
      LOG_FILE = "/data/log/my.log";
    };
    environmentFiles = [ config.sops.secrets.vaultwarden_env.path ];
  };

  # HTTPS through Tailscale Serve, same port as on the old host:
  # https://nidavellir.<tailnet>.ts.net:8122 → the container
  systemd.services.tailscale-serve-vaultwarden = {
    description = "Tailscale Serve: HTTPS for Vaultwarden";
    after       = [ "tailscaled.service" "tailscaled-autoconnect.service" "docker-vaultwarden.service" ];
    wants       = [ "tailscaled.service" ];
    wantedBy    = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = "${lib.getExe config.services.tailscale.package} serve --bg --https=8122 http://127.0.0.1:8122";
  };

  sops.secrets.vaultwarden_env = { };
}
