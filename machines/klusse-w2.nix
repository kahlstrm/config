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
  # The Katalyst proof of concept's rustfs key, as shell exports in `env`, from the Secret disk
  # katalyst-s3 (infra/local-kubernetes/apps/compute-runners/klusse-w2.yaml). Not under
  # /run/keys, which only root and the keys group can enter: threads run as amp. Only amp may
  # read it; the disk's Rock Ridge permissions would make it world-readable.
  fileSystems."/run/katalyst-s3" = {
    device = "/dev/disk/by-id/virtio-katalyst-s3";
    fsType = "iso9660";
    options = [
      "ro"
      "nofail"
      "uid=amp"
      "gid=amp"
      "mode=0400"
      "dmode=0500"
      "overriderockperm"
    ];
  };
  # Portals start their proxy with node, and threads open them with the runner's amp CLI.
  environment.systemPackages = [
    config.local.ampRunner.package
    pkgs.nodejs
  ];
  nixpkgs.hostPlatform = "x86_64-linux";
  nixpkgs.config.allowUnfreePredicate = package: lib.getName package == "amp-cli";
}
