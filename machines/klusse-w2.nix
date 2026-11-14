# The compute runner VM on klusse's worker w2, runner ID klusse-w2.
{ lib, pkgs, ... }:
{
  imports = [
    ../modules/amp-runner.nix
    ../modules/klusse-runner
  ];
  networking.hostName = "klusse-w2";
  # Shared with the workspace, serving portals: workspace members' threads get root here and can
  # read the account's Amp token (infra/docs/adr/2026-11-14-temporary-compute-runners.md).
  # Portals need a newer amp-cli than the flake's nixpkgs has. Revert both to stop sharing.
  local.ampRunner.share = true;
  local.ampRunner.package = pkgs.amp-cli.overrideAttrs (_: {
    version = "0.0.1794686429-g79beb3";
    src = pkgs.fetchurl {
      url = "https://static.ampcode.com/cli/0.0.1794686429-g79beb3/amp-linux-x64-baseline.gz";
      hash = "sha256-YtYMEeUntmAK6ewLmZkFTORQtFeoEAE3YEPCC9/7d74=";
    };
  });
  nixpkgs.hostPlatform = "x86_64-linux";
  nixpkgs.config.allowUnfreePredicate = package: lib.getName package == "amp-cli";
}
