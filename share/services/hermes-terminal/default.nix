{ config, lib, pkgs, ... }:
# The image behind Hermes's terminal.backend = "docker": the sandbox its terminal
# commands and Claude Code delegations run in. Hermes starts it itself
# (`docker run … sleep infinity`, then `docker exec bash`), so the image needs
# only bash, sleep, a writable /tmp and the tools.
let
  image = pkgs.dockerTools.buildLayeredImage {
    name = "hermes-terminal";
    tag  = "latest";
    contents = with pkgs; [
      bashInteractive coreutils findutils diffutils gnugrep gnused gawk
      gnutar gzip which less procps curl git nodejs claude-code
      dockerTools.binSh dockerTools.usrBinEnv dockerTools.fakeNss dockerTools.caCertificates
    ];
    extraCommands = "mkdir -m 1777 tmp";
    config.Env = [
      "PATH=/bin"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "DISABLE_AUTOUPDATER=1"   # Claude Code lives in the read-only store; updates come with nixpkgs
    ];
  };
in
{
  homelab.unfree = [ "claude-code" ];

  # Hermes runs `docker` as itself: the CLI on its service PATH, the socket via
  # the group, and the image loaded before the gateway starts
  users.users.hermes.extraGroups = [ "docker" ];
  services.hermes-agent.extraPackages = [ config.virtualisation.docker.package ];
  systemd.services.hermes-agent = {
    wants = [ "hermes-terminal-image.service" ];
    after = [ "hermes-terminal-image.service" ];
  };

  # The WebUI is a separate service that runs the agent in its own process, and its
  # module sets no PATH: without this a WebUI session logs "Docker is not installed"
  # and loses the terminal and file tools. Same CLI, same image ordering.
  systemd.services.hermes-webui = {
    path  = [ config.virtualisation.docker.package ];
    wants = [ "hermes-terminal-image.service" ];
    after = [ "hermes-terminal-image.service" ];
  };

  # Load the image into Docker; runs again only when the image changes
  systemd.services.hermes-terminal-image = {
    description = "Load the hermes-terminal image into Docker";
    after       = [ "docker.service" ];
    requires    = [ "docker.service" ];
    wantedBy    = [ "multi-user.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
    };
    script = "${lib.getExe config.virtualisation.docker.package} load < ${image}";
  };
}
