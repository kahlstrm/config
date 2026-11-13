# The backup credentials (modules/backup.nix) from the private secrets repository's backup/
# directory, encrypted to every host that backs up and the recovery key. sops-nix decrypts each
# with the host's SSH host key. A credential whose file the repository doesn't hold yet stays
# unset, and the backup units say the credentials are missing.
{
  config,
  lib,
  inputs,
  ...
}:
let
  files = lib.filterAttrs (_: name: builtins.pathExists "${inputs.secrets}/backup/${name}") {
    passwordFile = "password";
    sshKeyFile = "ssh-key";
    offsiteRepositoryFile = "offsite";
  };
in
{
  imports = [ inputs.sops-nix.nixosModules.sops ];
  # age's native SSH support, which decrypts files encrypted to the ssh-ed25519 public key;
  # converting the key to an age identity would not.
  sops.age.sshKeyFile = "/etc/ssh/ssh_host_ed25519_key";
  sops.age.sshKeyPaths = [ ];
  sops.gnupg.sshKeyPaths = [ ];
  sops.secrets = lib.mapAttrs' (
    _: name:
    lib.nameValuePair "backup-${name}" {
      sopsFile = "${inputs.secrets}/backup/${name}";
      format = "binary";
    }
  ) files;
  local.backup.credentials = lib.mapAttrs (_: name: config.sops.secrets."backup-${name}".path) files;
}
