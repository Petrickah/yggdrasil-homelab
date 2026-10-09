{ config, pkgs, lib, ... }:
let
  cfg = config.homelab.bifrost;
in
{
  options.homelab.bifrost = {
    enable = lib.options.mkEnableOption "Allow bridging the containers together";
    users = lib.options.mkOption {
      description = "Attribute set of { username = sshPublicKey } for every user this container should have.";
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        admin = "ssh-ed25519 AAAA...";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Lets `bootstrap.py switch` copy a closure built elsewhere onto this VM
    nix.settings.trusted-users = [ "@wheel" ];

    # Console password (a hash, never the password itself) for emergency access
    # from the Proxmox console only — PasswordAuthentication is off for SSH, see
    # below. Decrypted before the users are created, hence neededForUsers.
    sops.secrets.console_password = {
      sopsFile       = ../share/secrets/common.yaml;
      neededForUsers = true;
    };

    # Defining every user for this container from cfg.users (name -> SSH key).
    users.users = lib.mapAttrs (name: sshKey: {
      isNormalUser = true;
      extraGroups = [ "wheel" ]; # Grants sudo access
      openssh.authorizedKeys.keys = [ sshKey ];
      hashedPasswordFile = config.sops.secrets.console_password.path;
    }) cfg.users;

    # Enable OpenSSH server
    services.openssh.enable = true;
    services.openssh.openFirewall = false;
    services.openssh.settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };

    # Enable passwordless sudo for every defined user.
    security.sudo.extraRules = [{
      users = lib.attrNames cfg.users;
      commands = [{
        command = "ALL";
        options = [ "NOPASSWD" ];
      }];
    }];
  };
}