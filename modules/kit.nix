{ config, lib, pkgs, kitSource, ... }:
# kitSource — the repository minus data, plaintext secrets, state and build
# results — is defined once in flake.nix; every machine carries the same one.
{
  options.homelab.services = lib.mkOption {
    description = ''
      Services with data in /var/lib/services/<name> on this host. The data is
      copied there once, from share/services/<name>/data, by `bootstrap.py seed`.
    '';
    default     = { };
    type        = lib.types.attrsOf (lib.types.submodule {
      options = {
        owner = lib.mkOption {
          description = "user:group to give the copied data; null keeps the source's own (what the image expects after a migration).";
          type        = lib.types.nullOr lib.types.str;
          default     = null;
        };
      };
    });
  };

  config = {
    # /etc/nixos is a read-only symlink into the store, updated on every switch
    environment.etc."nixos".source = kitSource;

    # Operator tools, so any machine built from here can bring up the others
    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "terraform" ];
    environment.systemPackages = with pkgs; [ terraform sops age python3 mkpasswd ];
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
  };
}
