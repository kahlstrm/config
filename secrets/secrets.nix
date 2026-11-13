# amp-runner-kubernetes-token.age is encrypted with age to pannu's host key alone and is not
# listed here, so `agenix -r` skips it; machines/pannu.nix says how to write it.
let
  sshKeys = import ../lib/ssh-keys.nix;
in
{
  "agent-github-app.age".publicKeys = [
    sshKeys.recovery
    sshKeys.hosts."pannu-agents"
  ];
  "agent-kubernetes-token.age".publicKeys = [
    sshKeys.recovery
    sshKeys.hosts."pannu-agents"
  ];
  "agent-talosconfig.age".publicKeys = [
    sshKeys.recovery
    sshKeys.hosts."pannu-agents"
  ];
  "headscale-oidc.age".publicKeys = [
    sshKeys.recovery
    sshKeys.hosts."poenttoe.kalski.xyz"
  ];
}
