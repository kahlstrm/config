# A Mac as an always-on host for coding agents: T3 Code reachable over
# Tailscale, deploys that survive T3 restarts, optional Opper models, a health
# check and agent instructions. Not imported by default; see
# docs/agents-macos.md.
{ config, lib, ... }:
{
  imports = [
    ./t3.nix
    ./deploy.nix
    ./opper.nix
    ./doctor.nix
    ./instructions.nix
  ];

  options.local.agentHost.alwaysOn.enable =
    lib.mkEnableOption "never sleeping, and restarting after a power failure or freeze";

  config = lib.mkIf config.local.agentHost.alwaysOn.enable {
    power.sleep.computer = "never";
    power.restartAfterPowerFailure = true;
    power.restartAfterFreeze = true;
  };
}
