{
  description = "A NixOS Homelab Configuration for Proxmox";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, sops-nix, ... }:
    let
      system = "x86_64-linux";
      lib    = nixpkgs.lib;
      pkgs   = import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "terraform" ];
      };

      # Everything specific to *this* installation — addresses, Proxmox host,
      # SSH key — lives in site.json (gitignored; see site.example.json).
      site =
        if builtins.pathExists ./site.json then builtins.fromJSON (builtins.readFile ./site.json)
        else throw "site.json not found — copy site.example.json to site.json and fill in your values";

      # The infrastructure kit: every host, every module, Terraform, scripts and
      # the encrypted secrets — never service data, plaintext secrets, state or
      # build results (data holds secrets of its own: it goes straight to the VMs
      # with `bootstrap.py seed`). The same for every machine: it becomes their
      # /etc/nixos, and `.#kit` is it as one archive.
      fs = lib.fileset;
      serviceDirs = lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./share/services));
      kitSource = fs.toSource {
        root = ./.;
        fileset = fs.difference ./. (fs.unions ([
          (fs.maybeMissing ./results)
          (fs.maybeMissing ./__pycache__)
          (fs.maybeMissing ./.git)
          (fs.maybeMissing ./share/terraform/.terraform)
          (fs.fileFilter (f: lib.hasPrefix "terraform.tfstate" f.name || lib.hasSuffix ".tfvars.json" f.name) ./share/terraform)
          # Only encrypted files travel: sops' *.yaml and the passphrase-protected admin-key.age
          (fs.fileFilter (f: !(f.hasExt "yaml" || f.hasExt "age")) ./share/secrets)
          (fs.fileFilter (f: f.name == ".env") ./share/services)
        ] ++ lib.concatMap (name: [
          (fs.maybeMissing (./share/services + "/${name}/data"))
          (fs.maybeMissing (./share/services + "/${name}/auth"))
        ]) serviceDirs));
      };

      # Every hosts/<hostname>.nix is a VM; anything under hosts/_parked/ is not
      hosts = map (lib.removeSuffix ".nix") (lib.attrNames (lib.filterAttrs
        (name: type: type == "regular" && lib.hasSuffix ".nix" name)
        (builtins.readDir ./hosts)));

      mkHost = hostname: lib.nixosSystem {
        inherit system;
        specialArgs = { inherit site kitSource; };
        modules = [
          ./hosts/${hostname}.nix
          ./modules/proxmox.nix
          ./modules/heimdall.nix
          ./modules/bifrost.nix
          ./modules/kit.nix
          ./modules/template.nix
          ./modules/sops.nix
          sops-nix.nixosModules.sops
        ];
      };

      homelabConfigurations = lib.genAttrs hosts mkHost;

      # Yggdrasil: the root LXC everything else can be rebuilt from — not a VM,
      # so it lives in operator/ and gets only the kit, no VM modules.
      yggdrasil = lib.nixosSystem {
        inherit system;
        specialArgs = { inherit site kitSource; };
        modules = [ ./operator/yggdrasil.nix ./modules/kit.nix ];
      };
    in
    {
      # Used with `nixos-rebuild --flake .#<hostname>`
      nixosConfigurations = homelabConfigurations // { inherit yggdrasil; };

      # Build via: nix build .#<hostname>-{template,mk-qcow2}, .#yggdrasil-template, .#kit
      packages.${system} = lib.concatMapAttrs (hostname: host: {
        "${hostname}-template" = host.config.system.build.template;
        "${hostname}-mk-qcow2" = host.config.system.build.mkQcow2;
      }) homelabConfigurations // {
        yggdrasil-template = yggdrasil.config.system.build.tarball;

        # `tar --zstd -xf homelab-kit.tar.zst` gives ./homelab/
        kit = pkgs.runCommand "homelab-kit.tar.zst" { nativeBuildInputs = [ pkgs.zstd ]; } ''
          tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner --mode=u+w \
            --transform 's,^\.,homelab,' -C ${kitSource} -c . | zstd -T0 -19 > $out
        '';
      };

      # Operator tools on a machine that isn't one of the VMs: `nix develop`
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [ terraform sops age python3 mkpasswd ];
      };
    };
}
