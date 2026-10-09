{ config, lib, pkgs, ... }:
let
  host     = config.networking.hostName;
  toplevel = config.system.build.toplevel;

  # Services that ship initial data with this host (seed = null is skipped)
  seeds = lib.filterAttrs (_: svc: svc.seed != null) config.homelab.services;

  # The seed is read back from the kit (kit.nix) rather than copied on its own,
  # so the data exists only once in the store.
  seedSource = svc: "${config.system.build.kitSource}/${lib.removePrefix "./" (lib.path.removePrefix ../. svc.seed)}";

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
    template.diskSize = lib.mkOption {
      description = "Size of the raw disk mk-qcow2.sh creates; Proxmox grows it on import.";
      type        = lib.types.str;
      default     = "8G";
    };
  };

  config = {
    # Copy each seed once; a service that already has data is never touched again
    systemd.services = lib.mapAttrs' (name: svc: lib.nameValuePair "homelab-seed-${name}" {
      description = "Seed /var/lib/services/${name} from the Nix store";
      wantedBy    = [ "multi-user.target" ];
      before      = [ "docker-${name}.service" ];
      requiredBy  = lib.optional (config.virtualisation.oci-containers.containers ? ${name}) "docker-${name}.service";
      unitConfig.ConditionPathExists = "!/var/lib/services/${name}";
      serviceConfig.Type = "oneshot";
      script = ''
        mkdir -p /var/lib/services
        rm -rf /var/lib/services/.${name}.tmp
        cp -r --no-preserve=mode,ownership ${seedSource svc} /var/lib/services/.${name}.tmp
        chown -R ${svc.owner} /var/lib/services/.${name}.tmp
        mv /var/lib/services/.${name}.tmp /var/lib/services/${name}
      '';
    }) seeds // {
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
  };
}
