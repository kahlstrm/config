{ lib, ... }:
let
  sshKeys = import ../lib/ssh-keys.nix;
in
{
  programs.ssh.knownHosts = lib.mapAttrs (_: publicKey: { inherit publicKey; }) sshKeys.hosts;
}
