{ config, lib, pkgs, kitSource, ... }:
# kitSource — the repository minus data, plaintext secrets, state and build
# results — is defined once in flake.nix; every machine carries the same one.
let
  host     = config.networking.hostName;
  toplevel = config.system.build.toplevel;

  # A ready-made EFI System Partition: the same layout systemd-boot-builder.py
  # produces, so the first `nixos-rebuild switch` simply takes it over.
  efi = "${config.systemd.package}/lib/systemd/boot/efi/systemd-bootx64.efi";
  esp = pkgs.runCommand "esp-${host}" { } ''
    mkdir -p $out/EFI/BOOT $out/EFI/systemd $out/EFI/nixos $out/loader/entries
    cp ${efi} $out/EFI/BOOT/BOOTX64.EFI
    cp ${efi} $out/EFI/systemd/systemd-bootx64.efi
    cp ${toplevel}/kernel $out/EFI/nixos/kernel.efi
    cp ${toplevel}/initrd $out/EFI/nixos/initrd.efi

    cat > $out/loader/loader.conf <<EOF
    default nixos-generation-1.conf
    EOF

    cat > $out/loader/entries/nixos-generation-1.conf <<EOF
    title NixOS
    version Generation 1 (template)
    linux /EFI/nixos/kernel.efi
    initrd /EFI/nixos/initrd.efi
    options init=${toplevel}/init ${toString config.boot.kernelParams}
    EOF
  '';

  label = mount: lib.removePrefix "/dev/disk/by-label/" config.fileSystems.${mount}.device;
in
{
  options.homelab = {
    unfree = lib.mkOption {
      description = "Names of unfree packages allowed on this machine; each module adds its own.";
      type        = lib.types.listOf lib.types.str;
      default     = [ ];
    };
    template.diskSize = lib.mkOption {
      description = "Size of the raw disk mk-qcow2.sh creates; Proxmox grows it on import.";
      type        = lib.types.str;
      default     = "8G";
    };
    services = lib.mkOption {
      description = ''
        Services with data in /var/lib/services/<name> on this host. `bootstrap.py
        backup` archives that data to the NAS, encrypted; `restore` puts it back.
      '';
      default     = { };
      type        = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          units = lib.mkOption {
            description = "Units stopped while the data is archived or replaced, so databases are consistent.";
            type        = lib.types.listOf lib.types.str;
            default     = [ "docker-${name}.service" ];
          };
          exclude = lib.mkOption {
            description = "Paths inside the data left out of the archive (and kept as they are on restore) — e.g. what Syncthing brings back anyway.";
            type        = lib.types.listOf lib.types.str;
            default     = [ ];
          };
        };
      }));
    };
  };

  config = lib.mkMerge [
    # Every machine, VMs and containers alike
    {
      # /etc/nixos is a read-only symlink into the store, updated on every switch
      environment.etc."nixos".source = kitSource;

      # Operator tools, so any machine built from here can bring up the others
      homelab.unfree = [ "terraform" ];
      nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) config.homelab.unfree;
      environment.systemPackages = with pkgs; [ terraform sops age python3 mkpasswd ];
      nix.settings.experimental-features = [ "nix-command" "flakes" ];
    }

    # VMs only: a container (Yggdrasil) has no kernel or ESP, and its
    # proxmox-lxc module already registers the store paths on first boot
    (lib.mkIf (!config.boot.isContainer) {
      systemd.services = {
        # The template's store has no Nix database yet — load it on first boot.
        # Same as nixpkgs' nixos/modules/virtualisation/proxmox-lxc.nix.
        register-nix-paths = {
          description = "Register Nix store paths shipped in the template";
          unitConfig  = {
            DefaultDependencies = false;
            ConditionPathExists = "/nix-path-registration";
          };
          wantedBy  = [ "sysinit.target" ];
          before    = [ "sysinit.target" "shutdown.target" "nix-daemon.socket" "nix-daemon.service" ];
          after     = [ "local-fs.target" ];
          conflicts = [ "shutdown.target" ];
          restartIfChanged = false;
          serviceConfig = {
            Type            = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ${lib.getExe' config.nix.package.out "nix-store"} --load-db < /nix-path-registration
            rm /nix-path-registration

            # nixos-rebuild also requires a "system" profile
            ${lib.getExe' config.nix.package.out "nix-env"} -p /nix/var/nix/profiles/system --set /run/current-system
          '';
        };
      };

      # Build via: nix build .#<hostname>-template
      system.build.template = pkgs.callPackage "${pkgs.path}/nixos/lib/make-system-tarball.nix" {
        fileName      = "vztmpl-nixos-${host}";
        storeContents = [{ object = toplevel; symlink = "none"; }];
        contents      = [
          { source = "${toplevel}/init"; target = "/sbin/init"; }
          { source = esp;                target = "/boot"; }
        ];
        compressCommand      = "zstd -T0 -12";
        compressionExtension = ".zst";
        extraInputs          = [ pkgs.zstd ];
      };

      # Build via: nix build .#<hostname>-mk-qcow2
      system.build.mkQcow2 = pkgs.replaceVarsWith {
        src          = ../share/scripts/mk-qcow2.sh;
        isExecutable = true;
        # Keep `#!/usr/bin/env bash`: it runs on Proxmox, which has no /nix/store bash
        dontPatchShebangs = true;
        replacements = {
          espLabel  = label "/boot";
          rootLabel = label "/";
          diskSize  = config.homelab.template.diskSize;
        };
      };
    })
  ];
}
