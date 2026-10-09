{ config, lib, ... }:
let
  hostFile = ../share/secrets + "/${config.networking.hostName}.yaml";
in
{
  # The host's age key is written here by mk-qcow2.sh (--age-key-stdin) when
  # the image is created — it never travels in the archive.
  sops.age.keyFile      = "/var/lib/sops-nix/key.txt";
  sops.age.generateKey  = false;
  sops.age.sshKeyPaths  = [ ];
  sops.gnupg.sshKeyPaths = [ ];

  # Service secrets come from share/secrets/<hostname>.yaml; shared ones set
  # their own sopsFile (see heimdall.nix).
  sops.defaultSopsFile = if builtins.pathExists hostFile then hostFile else ../share/secrets/common.yaml;
}
