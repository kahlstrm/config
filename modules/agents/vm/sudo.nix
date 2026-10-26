{ config, lib, ... }:
{
  # The VM is the isolation boundary; guest root grants no host access.
  users.users.${config.local.agentEnvironment.user}.extraGroups = [ "wheel" ];
  security.sudo.wheelNeedsPassword = false;
  # Agents run under t3code; the flag would stop their setuid sudo.
  systemd.services.t3code.serviceConfig.NoNewPrivileges = lib.mkForce false;
}
