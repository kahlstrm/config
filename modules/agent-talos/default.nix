# Read-only Talos API access (os:reader) for agents, active once the client config is enrolled.
# Enroll from the repository root with an admin talosconfig, using the talos-api-* addresses
# from modules/agents/vm/settings.nix:
#   talosctl config new --roles os:reader --crt-ttl 8760h agent-talosconfig
#   talosctl --talosconfig agent-talosconfig config endpoint 10.10.10.11 10.10.10.12 10.10.10.13
#   talosctl --talosconfig agent-talosconfig config node 10.10.10.11
#   AGENIX_RULES=secrets/secrets.nix agenix --edit agent-talosconfig.age < agent-talosconfig && rm agent-talosconfig
# Commit the secret and deploy. The client certificate expires after a year; re-enroll
# before then. Delete the secret to revoke access from the agent environment.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  talosconfig = ../../secrets/agent-talosconfig.age;
  path = config.age.secrets.agent-talosconfig.path;
in
{
  config = lib.mkIf (builtins.pathExists talosconfig) {
    age.secrets.agent-talosconfig = {
      file = talosconfig;
      owner = "agent";
      mode = "0400";
    };
    environment.systemPackages = [ pkgs.talosctl ];
    environment.sessionVariables.TALOSCONFIG = path;
    systemd.services.t3code.environment.TALOSCONFIG = path;
    local.agentEnvironment.credentials.talos = {
      talosconfig = path;
      access = "read-only Talos API (os:reader) through the talos-api-* services: node logs, dmesg, processes, stats and non-sensitive resources; reach workers with -n through a control plane; no writes, upgrades, reboots or machine secrets";
    };
  };
}
