{ config, lib, pkgs, site, ... }:
# A workstation for projects and homelab work, reached with VS Code Remote-SSH:
# Claude Code, the vault and Claude Code's own config, both kept in step with
# the Mac Mini by Syncthing. Homelab work needs the vault (notes, governance)
# and x86_64 Nix builds, so it happens here; Yggdrasil stays the agent-free
# root everything can be rebuilt from.
let
  user = builtins.head (builtins.attrNames config.homelab.bifrost.users);
  home = config.users.users.${user}.home;

  # Ignore rules are per device: the same ones the other machines use, put in
  # place before the first sync, and never replaced once there
  vaultIgnore = pkgs.writeText "vault-stignore" ''
    // macOS/Windows filesystem junk
    .DS_Store
    Thumbs.db
    desktop.ini

    // Obsidian per-device UI state — not shared vault content, causes needless conflicts
    .obsidian/workspace.json
    .obsidian/workspace-mobile.json
    .obsidian/cache

    // Editor/OS temp files
    *.tmp
    ~$*

    // 10_Homelab is a git repo (github.com/Petrickah/yggdrasil-homelab): git syncs
    // it between machines. Only its vault-only files (notes, CLAUDE.md,
    // _habitat.md) go through Syncthing.
    // Exceptions first — Syncthing applies the first pattern that matches.
    !/10_Homelab/share/notes
    !/10_Homelab/CLAUDE.md
    !/10_Homelab/_habitat.md
    /10_Homelab
  '';
  # Each machine logs into Claude Code on its own
  claudeIgnore = pkgs.writeText "claude-stignore" ''
    .credentials.json
  '';
in
{
  environment.systemPackages = with pkgs; [ git gh ripgrep jq ];

  # Claude Code is the native install (`curl -fsSL https://claude.ai/install.sh | bash`,
  # into ~/.local/bin), which updates itself: it releases far more often than
  # nixpkgs follows. It runs here thanks to nix-ld, below.
  environment.localBinInPath = true;

  # direnv (+ nix-direnv, which caches the shells) for the VS Code direnv
  # extension: a folder's .envrc loads its flake's dev shell on its own
  programs.direnv.enable = true;

  # VS Code Remote-SSH runs a generic Node server; nix-ld gives it the /lib64 loader
  programs.nix-ld.enable = true;

  services.syncthing = {
    enable           = true;
    user             = user;
    group            = "users";
    dataDir          = home;
    configDir        = "${home}/.config/syncthing";
    openDefaultPorts = true;
    guiAddress       = "127.0.0.1:8384";
    settings = {
      gui.insecureSkipHostcheck = true;          # behind Tailscale Serve
      devices."mac-mini" = {
        id        = site.syncthing.mac-mini.id;
        addresses = [ site.syncthing.mac-mini.address ];
      };
      # The same folder IDs as on the Mac, or Syncthing sees new folders
      folders.vault = {
        label   = "Obsidian Vault";
        path    = "${home}/vault";
        devices = [ "mac-mini" ];
      };
      folders."svxsw-p96es" = {
        label   = "Claude Configuration";
        path    = "${home}/.claude";
        devices = [ "mac-mini" ];
      };
    };
  };
  homelab.heimdall.serve."8384" = "http://127.0.0.1:8384";

  # Not tmpfiles C + z: tmpfiles ignores a second line for the same path, so
  # the copy stayed root's and read-only. This one sets the owner, once.
  systemd.services.workstation-stignore = {
    description = "Put Syncthing's ignore rules in place before the first sync";
    wantedBy    = [ "multi-user.target" ];
    before      = [ "syncthing.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      for rule in "${home}/vault/.stignore=${vaultIgnore}" "${home}/.claude/.stignore=${claudeIgnore}"; do
        target=''${rule%%=*}
        [ -e "$target" ] || install -D -o ${user} -g users -m 0644 "''${rule#*=}" "$target"
      done
    '';
  };

  systemd.tmpfiles.rules = [
    "d ${home}/vault   0750 ${user} users - -"
    "d ${home}/.claude 0700 ${user} users - -"
    # Claude Code keys a project (memory and sessions) by its launch path; this
    # machine's (/home/<user>/vault) is the same project the other machines use.
    # Plain L: made only where nothing exists yet, never replacing real sessions
    "d ${home}/.claude/projects 0700 ${user} users - -"
    "L ${home}/.claude/projects/-home-${user}-vault - - - - -home-hermes-vault"
  ];
}
