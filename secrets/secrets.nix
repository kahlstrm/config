let
  sshKeys = import ../lib/ssh-keys.nix;
in
{
  "headscale-oidc.age".publicKeys = sshKeys.administrators ++ [ sshKeys.hosts."poenttoe.kalski.xyz" ];
}
