{ config, lib, pkgs, ... }:
let
  host = config.networking.hostName;
  fs   = lib.fileset;
  root = ../.;

  # Services that ship initial data with this host (seed = null is skipped)
  seeds = lib.filterAttrs (_: svc: svc.seed != null) config.homelab.services;

  # Every share/services/<name>/data directory, for any host
  serviceDirs = lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../share/services));
  dataDirs    = map (name: fs.maybeMissing (../share/services + "/${name}/data")) serviceDirs;
  authDirs    = map (name: fs.maybeMissing (../share/services + "/${name}/auth")) serviceDirs;

  # The infrastructure kit: every host, every module, Terraform, scripts and the
  # encrypted secrets — never plaintext secrets, state or build results.
  # Only *this* host's service data is added back, so it can be seeded on boot.
  flakeSource = fs.toSource {
    inherit root;
    fileset = fs.unions ([
      (fs.difference root (fs.unions ([
        (fs.maybeMissing ../results)
        (fs.maybeMissing ../__pycache__)
        (fs.maybeMissing ../.git)
        (fs.maybeMissing ../share/terraform/.terraform)
        (fs.fileFilter (f: lib.hasPrefix "terraform.tfstate" f.name || lib.hasSuffix ".tfvars.json" f.name) ../share/terraform)
        # Only encrypted files travel: sops' *.yaml and the passphrase-protected admin-key.age
        (fs.fileFilter (f: !(f.hasExt "yaml" || f.hasExt "age")) ../share/secrets)
        (fs.fileFilter (f: f.name == ".env") ../share/services)
      ] ++ dataDirs ++ authDirs)))
    ] ++ lib.mapAttrsToList (_: svc: svc.seed) seeds);
  };
in
{
  options.homelab.services = lib.mkOption {
    description = "Services whose initial data is copied once into /var/lib/services/<name>.";
    default     = { };
    type        = lib.types.attrsOf (lib.types.submodule {
      options = {
        seed = lib.mkOption {
          description = "Directory inside this repository with the initial data, or null.";
          type        = lib.types.nullOr lib.types.path;
          default     = null;
        };
        owner = lib.mkOption {
          description = "user:group that owns the copied data.";
          type        = lib.types.str;
          default     = "root:root";
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

    # For template.nix, which seeds service data straight out of the kit
    system.build.kitSource = flakeSource;

    # Build via: nix build .#<hostname>-kit
    # Just the kit (/etc/nixos), for a machine that isn't one of the VMs:
    # `tar --zstd -xf homelab-kit-<hostname>.tar.zst` gives ./homelab/
    system.build.kit = pkgs.runCommand "homelab-kit-${host}.tar.zst" { nativeBuildInputs = [ pkgs.zstd ]; } ''
      tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner --mode=u+w \
        --transform 's,^\.,homelab,' -C ${flakeSource} -c . | zstd -T0 -19 > $out
    '';
  };
}
