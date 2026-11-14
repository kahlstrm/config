# The compute runner VM on klusse's worker w1, runner ID klusse-w1.
{ lib, ... }:
{
  imports = [
    ../modules/amp-runner.nix
    ../modules/klusse-runner
  ];
  networking.hostName = "klusse-w1";
  nixpkgs.hostPlatform = "x86_64-linux";
  nixpkgs.config.allowUnfreePredicate = package: lib.getName package == "amp-cli";
}
