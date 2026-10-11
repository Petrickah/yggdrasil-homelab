{ config, lib, pkgs, hermes-agent, ... }:
{
  imports = [
    hermes-agent.nixosModules.default
  ];

  # Data in /var/lib/services/hermes, copied once by `bootstrap.py seed`
  homelab.services.hermes.owner = "hermes:hermes";

  # Declare the Hermes Agent configuration
  services.hermes-agent = {
    enable              = true;
    addToSystemPackages = true;
    backend.mode        = "dashboard";
    stateDir            = "/var/lib/services/hermes";
    environmentFiles    = [ config.sops.secrets."hermes_env".path ];
  };

  # Reached only through Tailscale Serve: Dashboard over HTTPS
  homelab.heimdall.serve."9119" = "http://127.0.0.1:9119";

  # Define the secrets variable for Hermes Agent Environment file.
  sops.secrets."hermes_env" = { format = "yaml"; };
}
