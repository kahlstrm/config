# The compute runner VM on klusse's worker w1, runner ID klusse-w1, which also runs the
# self-hosted orbs of the provider klusse-w1 as Docker containers.
{ lib, pkgs, ... }:
{
  imports = [
    ../modules/amp-runner.nix
    ../modules/klusse-runner
  ];
  networking.hostName = "klusse-w1";
  # Also for the workspace: its members' orbs get root here and can read the account's Amp
  # token (infra/docs/adr/2026-11-19-docker-orbs-in-runner-vms.md).
  local.klusseRunner.orbs = {
    enable = true;
    workspace = true;
  };
  # Scripts and tools that expect /bin/bash, as on klusse-w2.
  systemd.tmpfiles.rules = [ "L+ /bin/bash - - - - ${pkgs.bashInteractive}/bin/bash" ];
  nixpkgs.hostPlatform = "x86_64-linux";
  nixpkgs.config.allowUnfreePredicate = package: lib.getName package == "amp-cli";
}
