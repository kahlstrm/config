# The compute runner VM on klusse's worker w2, runner ID klusse-w2.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ../modules/amp-runner.nix
    ../modules/klusse-runner
  ];
  networking.hostName = "klusse-w2";
  # Shared with the workspace, serving portals: workspace members' threads get root here and can
  # read the account's Amp token (infra/docs/adr/2026-11-14-temporary-compute-runners.md).
  # Revert this to stop sharing.
  local.ampRunner.share = true;
  # Portals start their proxy with node, and threads open them with the runner's amp CLI.
  environment.systemPackages = [
    config.local.ampRunner.package
    pkgs.nodejs
  ];
  nixpkgs.hostPlatform = "x86_64-linux";
  nixpkgs.config.allowUnfreePredicate = package: lib.getName package == "amp-cli";
}
