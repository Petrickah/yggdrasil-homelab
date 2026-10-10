{ config, lib, pkgs, site, ... }:
let
  # What clients see: the host's tailnet name, through Tailscale Serve
  domain = "${config.networking.hostName}.${site.tailnet}";
in
{
  # Data in /var/lib/services/gitea (repos, SQLite, SSH host keys), copied once
  # by `bootstrap.py seed`, keeping its ownership — uid 1000 is `git` in the image.
  homelab.services.gitea = { };

  virtualisation.docker.enable = true;
  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.gitea = {
    image = "gitea/gitea:1.27.2";
    volumes = [
      "/var/lib/services/gitea:/data"
      "/etc/localtime:/etc/localtime:ro"
    ];
    ports = [ "127.0.0.1:3000:3000" "127.0.0.1:2222:22" ];   # only Tailscale Serve reaches them
    environment = {
      GITEA__database__DB_TYPE         = "sqlite3";
      GITEA__server__DOMAIN            = domain;
      GITEA__server__ROOT_URL          = "https://${domain}:3000/";
      GITEA__server__SSH_DOMAIN        = domain;
      GITEA__server__SSH_PORT          = "2222";
      GITEA__server__SSH_LISTEN_PORT   = "22";
      GITEA__service__DISABLE_REGISTRATION = "true";
      GITEA__security__INSTALL_LOCK    = "true";
    };
  };

  # Web over HTTPS on the same port as before; git over SSH as raw TCP
  homelab.heimdall.serve."3000" = "http://127.0.0.1:3000";
  homelab.heimdall.serve."tcp:2222" = "tcp://127.0.0.1:2222";
}
