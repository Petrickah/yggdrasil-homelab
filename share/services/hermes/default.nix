{ config, lib, pkgs, site, hermes-agent, hermes-webui, ... }:
let
  cfg    = config.services.hermes-agent;
  groups = [ "messaging" "firecrawl" ];   # Discord + web.backend firecrawl
  hermes = cfg.package.override { extraDependencyGroups = groups; };
  python = hermes.python.pkgs;
  canon  = n: lib.toLower (builtins.replaceStrings [ "_" "." ] [ "-" "-" ] n);

  # Python packages Hermes's sealed venv already ships, read from its site-packages
  sealed = map (d: canon (builtins.head (lib.splitString "-" d)))
    (lib.filter (lib.hasSuffix ".dist-info")
      (builtins.attrNames (builtins.readDir "${hermes.passthru.hermesVenv}/${hermes.python.sitePackages}")));

  # mind-vault's dependencies minus what the venv has; each one stops pulling its
  # own dependencies in, so the plugin uses the venv's httpx, pydantic, numpy…
  pluginDeps = map (p: (p.out or p) // { requiredPythonModules = [ ]; })
    (lib.filter (p: p ? pname && p.pname != hermes.python.pname && !(lib.elem (canon p.pname) sealed))
      (python.requiredPythonModules [ python.qdrant-client python.fastembed ]));
in
{
  # settings.nix holds Hermes's own settings, mind-vault's instructions among
  # them (they describe the owner): gitignored, kept only in the kit (like site.json)
  imports = [
    hermes-agent.nixosModules.default
    hermes-webui.nixosModules.default
    ../hermes-terminal
  ] ++ lib.optional (builtins.pathExists ./settings.nix) ./settings.nix;

  # Data in /var/lib/services/hermes: state, sessions, WebUI and Syncthing's own
  # config. The vault (workspace) stays out of backups — Syncthing brings it back
  homelab.services.hermes = {
    units   = [ "hermes-agent.service" "hermes-backend.service" "hermes-webui.service" "syncthing.service" ];
    exclude = [ "workspace" ];
  };

  # Hermes downloads a generic Node.js for its npx MCP servers (filesystem,
  # obsidian); nix-ld provides the /lib64 loader NixOS doesn't have
  programs.nix-ld.enable = true;

  # Declare the Hermes Agent configuration
  services.hermes-agent   = {
    enable                = true;
    addToSystemPackages   = true;
    backend.mode          = "dashboard";
    stateDir              = "/var/lib/services/hermes";
    environmentFiles      = [ config.sops.secrets."hermes_env".path ];
    extraDependencyGroups = groups;
    extraPythonPackages   = pluginDeps;
  };

  # Reached only through Tailscale Serve: Dashboard over HTTPS
  homelab.heimdall.serve."9119" = "http://127.0.0.1:9119";

  # Define the secrets variable for Hermes Agent Environment file.
  sops.secrets."hermes_env" = { };

  # Hermes Agent works with a shared folder, the vault.
  # Enable Syncthing and configure the synced folder
  services.syncthing = {
    enable           = true;
    user             = "hermes";
    group            = "hermes";
    dataDir          = "/var/lib/services/hermes";
    configDir        = "/var/lib/services/hermes/.config/syncthing";
    openDefaultPorts = true;
    guiAddress       = "127.0.0.1:8384";
    settings = {
      gui.insecureSkipHostcheck = true;
      devices."hermes-agent" = {
        id        = site.syncthing.hermes-agent.id;
        addresses = [ site.syncthing.hermes-agent.address ];
      };
      folders.vault = {
        label   = "Obsidian Vault";
        path    = "/var/lib/services/hermes/workspace";
        devices = [ "hermes-agent" ];
      };
    };
  };

  # Reached only through Tailscale Serve: Syncthing Dashboard over HTTPS
  homelab.heimdall.serve."8384" = "http://127.0.0.1:8384";

  # Hermes Agent makes best use of a Web Interface; Hermes WebUI.
  # Enable and configure the user interface.
  services.hermes-webui = {
    enable           = true;
    user             = "hermes";
    group            = "hermes";
    stateDir         = "/var/lib/services/hermes";
    hermesHome       = "/var/lib/services/hermes/.hermes";
    host             = "127.0.0.1";
    port             = 8787;
    environmentFiles = [ config.sops.secrets."hermes_env".path ];
    # The same venv as the gateway, plus mind-vault's dependencies: the WebUI
    # runs the agent with that venv's python, not through the hermes wrapper
    agent.package    = hermes;
    extraEnvironment.PYTHONPATH = lib.makeSearchPath hermes.python.sitePackages pluginDeps;
  };

  # Reached only through Tailscale Serve: Hermes WebUI over HTTPS
  homelab.heimdall.serve."8787" = "http://127.0.0.1:8787";
}
