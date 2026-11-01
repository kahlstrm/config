{ config, lib, ... }:
{
  options.local.agentVM.passwordlessSudo = lib.mkOption {
    type = lib.types.bool;
    description = ''
      Whether the agent user gets passwordless root in the guest. Leave it off when
      the guest holds credentials that agents must reach only through an approval gate.
    '';
  };
  # The VM is the isolation boundary; guest root grants no host access.
  config = lib.mkIf config.local.agentVM.passwordlessSudo {
    users.users.${config.local.agentEnvironment.user}.extraGroups = [ "wheel" ];
    security.sudo.wheelNeedsPassword = false;
    # Agents run under t3code; the flag would stop their setuid sudo.
    systemd.services.t3code.serviceConfig.NoNewPrivileges = lib.mkForce false;
  };
}
