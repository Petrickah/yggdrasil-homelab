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

      # Every hosts/<hostname>.nix is a VM; anything under hosts/_parked/ is not
      hosts = map (lib.removeSuffix ".nix") (lib.attrNames (lib.filterAttrs
        (name: type: type == "regular" && lib.hasSuffix ".nix" name)
        (builtins.readDir ./hosts)));

      mkHost = hostname: lib.nixosSystem {
        inherit system;
        specialArgs = { inherit site; };
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
        specialArgs = { inherit site; };
        modules = [ ./operator/yggdrasil.nix ./modules/kit.nix ];
      };
    in
    {
      # Used with `nixos-rebuild --flake .#<hostname>`
      nixosConfigurations = homelabConfigurations // { inherit yggdrasil; };

      # Build via: nix build .#<hostname>-{template,kit,mk-qcow2}
      packages.${system} = lib.concatMapAttrs (hostname: host: {
        "${hostname}-template" = host.config.system.build.template;
        "${hostname}-mk-qcow2" = host.config.system.build.mkQcow2;
        "${hostname}-kit"      = host.config.system.build.kit;
      }) homelabConfigurations // {
        yggdrasil-template = yggdrasil.config.system.build.tarball;
        yggdrasil-kit      = yggdrasil.config.system.build.kit;
      };

      # Operator tools on a machine that isn't one of the VMs: `nix develop`
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [ terraform sops age python3 mkpasswd ];
      };
    };
}
