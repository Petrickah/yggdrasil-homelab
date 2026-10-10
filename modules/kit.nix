{ config, lib, pkgs, ... }:
let
  host = config.networking.hostName;
  fs   = lib.fileset;
  root = ../.;

  # Every share/services/<name>/data directory, for any host
  serviceDirs = lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../share/services));
  dataDirs    = map (name: fs.maybeMissing (../share/services + "/${name}/data")) serviceDirs;
  authDirs    = map (name: fs.maybeMissing (../share/services + "/${name}/auth")) serviceDirs;

  # The infrastructure kit: every host, every module, Terraform, scripts and the
  # encrypted secrets — never service data, plaintext secrets, state or build
  # results. Data holds secrets of its own (keys, tokens, private repos), and the
  # kit ends up in the world-readable store and on the NAS: data goes straight
  # to the VM instead (`bootstrap.py seed`).
  flakeSource = fs.toSource {
    inherit root;
    fileset = fs.difference root (fs.unions ([
      (fs.maybeMissing ../results)
      (fs.maybeMissing ../__pycache__)
      (fs.maybeMissing ../.git)
      (fs.maybeMissing ../share/terraform/.terraform)
      (fs.fileFilter (f: lib.hasPrefix "terraform.tfstate" f.name || lib.hasSuffix ".tfvars.json" f.name) ../share/terraform)
      # Only encrypted files travel: sops' *.yaml and the passphrase-protected admin-key.age
      (fs.fileFilter (f: !(f.hasExt "yaml" || f.hasExt "age")) ../share/secrets)
      (fs.fileFilter (f: f.name == ".env") ../share/services)
    ] ++ dataDirs ++ authDirs));
  };
in
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
    environment.etc."nixos".source = flakeSource;

    # Operator tools, so any machine built from here can bring up the others
    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "terraform" ];
    environment.systemPackages = with pkgs; [ terraform sops age python3 mkpasswd ];
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # Build via: nix build .#<hostname>-kit
    # Just the kit (/etc/nixos), for a machine that isn't one of the VMs:
    # `tar --zstd -xf homelab-kit-<hostname>.tar.zst` gives ./homelab/
    system.build.kit = pkgs.runCommand "homelab-kit-${host}.tar.zst" { nativeBuildInputs = [ pkgs.zstd ]; } ''
      tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner --mode=u+w \
        --transform 's,^\.,homelab,' -C ${flakeSource} -c . | zstd -T0 -19 > $out
    '';
  };
}
