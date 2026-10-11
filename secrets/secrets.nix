let
  sshKeys = import ../lib/ssh-keys.nix;
in
{
  "agent-github-fork.age".publicKeys = sshKeys.administrators ++ [ sshKeys.hosts."pannu-agents" ];
  "agent-github-upstream.age".publicKeys = sshKeys.administrators ++ [ sshKeys.hosts."pannu-agents" ];
  "headscale-oidc.age".publicKeys = sshKeys.administrators ++ [ sshKeys.hosts."poenttoe.kalski.xyz" ];
}
