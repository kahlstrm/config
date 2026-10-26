{ config, ... }:
{
  # The VM is the isolation boundary; guest root grants no host access.
  users.users.${config.local.agentEnvironment.user}.extraGroups = [ "wheel" ];
  security.sudo.wheelNeedsPassword = false;
}
