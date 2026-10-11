{ config, lib, pkgs, site, hermes-agent, ... }:
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
  # mind-vault.nix holds the plugin's instructions and tool descriptions, which
  # describe the owner: gitignored, kept only in the kit (like site.json)
  imports = [
    hermes-agent.nixosModules.default
    ../hermes-terminal
  ] ++ lib.optional (builtins.pathExists ./mind-vault.nix) ./mind-vault.nix;

  # Data in /var/lib/services/hermes, copied once by `bootstrap.py seed`
  homelab.services.hermes.owner = "hermes:hermes";

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

    mcpServers   = {
      filesystem = {
        command  = "npx";
        args     = [
          "-y"
          "@modelcontextprotocol/server-filesystem"
          "/var/lib/services/hermes/workspace"
        ];
      };
      obsidian   = {
        command  = "npx";
        args     = [
          "-y"
          "@bitbonsai/mcpvault@0.16.0"
          "/var/lib/services/hermes/workspace"
        ];
      };
    };

    settings = {
      plugins.enabled  = [ "mind-vault" ]; # Enable the mind-vault plugin
      dashboard.theme  = "ember";
      # Model Settings     (for reasoning)
      model.provider   = "openrouter";
      model.base_url   = "https://openrouter.ai/api/v1";
      model.default    = "openai/gpt-6-luna";
      # Terminal Settings  (commands run in the hermes-terminal sandbox, with the
      # vault mounted at /workspace; the container is reused, then recycled)
      terminal = {
        backend              = "docker";
        docker_image         = "hermes-terminal:latest";
        docker_mount_cwd_to_workspace = true;
        docker_workspace_dir = "/workspace";
        home_mode            = "auto";
        container_cpu        = 1;
        container_memory     = 5120;
        container_disk       = 51200;
        container_persistent = true;
        lifetime_seconds     = 300;
        timeout              = 180;
      };
      # Web Settings       (for Deep Research)
      web.backend      = "firecrawl";
      web.use_gateway  = false;
      # Default Compression (for sessions)
      compression.enabled = true;
      # Disable the normal memory provider
      memory.memory_enabled       = false;
      memory.user_profile_enabled = false;
      # Memory Settings    (for knowledge retrieval)
      memory.provider   = "mind-vault";
      memory.mind-vault = {
        url    = "https://${config.networking.hostName}.${site.tailnet}:6333";
        inject = [ "memories/USER.md" ];
        inject_max_chars = 20000;
        collection_name  = "mind-vault";
        embedding_model  = "sentence-transformers/all-MiniLM-L6-v2";
      };
    };
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
}
