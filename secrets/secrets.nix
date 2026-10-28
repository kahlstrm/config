let
  sshKeys = import ../lib/ssh-keys.nix;
in
{
  "agent-github-app.age".publicKeys = sshKeys.administrators ++ [ sshKeys.hosts."pannu-agents" ];
  "agent-kubernetes-token.age".publicKeys = sshKeys.administrators ++ [
    sshKeys.hosts."pannu-agents"
  ];
  "agent-talosconfig.age".publicKeys = sshKeys.administrators ++ [ sshKeys.hosts."pannu-agents" ];
  "headscale-oidc.age".publicKeys = sshKeys.administrators ++ [ sshKeys.hosts."poenttoe.kalski.xyz" ];
}
