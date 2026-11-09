# The ops runner: an Amp runner in the ops VM for privileged work, starting with applies of
# infra/local-networking (infra/docs/adr/2026-11-09-privileged-work-on-the-ops-runner.md).
#
# It runs as amp, not as the agent user, so nothing under /home/agent loads into its threads,
# including the personal instructions linked there, and it cannot read the T3 agent's
# credentials. It holds only what local-networking applies need: its own GCP key for the
# service account `networking.serviceAccount`, which may write local-networking's state and
# read the `local-networking` Secret Manager secret with the RouterOS credentials. infra/
# gcp-project grants that, applied from a maintainer's machine, never from ops.
#
# It asks before every tool call, file reads and shell commands included, and refuses
# commands that name its credentials or print environments, which hold the Amp key. The
# rules guide the agent; approvals are the boundary, since any approved command runs as amp
# and can read what amp can.
#
# One-time setup by a maintainer:
#
# 1. Register the runner's key. Create an Amp access token for the runner in Amp's security
#    settings (https://ampcode.com/settings/security; it starts with `sgamp_`), then store it
#    on pannu, which passes it to ops as the system credential amp-runner.token at boot
#    (`microvm.credentialFiles` below), and restart ops:
#      sudo install -m 0400 -o microvm -g kvm /dev/stdin /var/lib/microvms/ops/amp-runner.token
#      sudo systemctl restart microvm@ops
#    Paste the key at the first command's empty prompt and end it with Ctrl-D. The runner then
#    shows as `ops` in Amp's runner list. To revoke, delete the key in Amp and truncate the file.
# 2. Upload the GCP key. ops-networking-credentials generates the key on ops at boot, into
#    /var/lib/ops-networking, readable by amp only. Upload its certificate as a key of the
#    service account (the org policy iam.disableServiceAccountKeyUpload would block it). The
#    directory is 0711, so the agent user can read the certificate by name but not list the
#    directory or read the key:
#      ssh pannu-ops cat /var/lib/ops-networking/gcp.crt > ops-networking.crt
#      gcloud iam service-accounts keys upload ops-networking.crt --iam-account <account>
#    and set local.agentOps.networking.keyId in machines/ops.nix to the last segment of the
#    printed key name. The key expires with the certificate after a year: then remove gcp.key
#    and gcp.crt there, restart ops-networking-credentials, and upload the new certificate.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentOps.networking;
  tool = pkgs.callPackage ./credentials-package.nix { };
  user = "amp";
  # The host's copy, which the host creates empty so the VM boots before a key is installed.
  hostToken = "/var/lib/microvms/${config.local.agentVM.name}/amp-runner.token";
  gcpEnabled = cfg.serviceAccount != null && cfg.keyId != null;
  shellTools = {
    Bash = "cmd";
    shell_command = "command";
    async_shell_command = "command";
  };
  # Commands that read the runner's credentials or print its environment, which holds the Amp
  # key, are refused even when approved by mistake. The imported key also sits under
  # /run/credentials, readable by amp.
  refused = [
    "*${cfg.stateDirectory}*"
    "*${cfg.runtimeDirectory}*"
    "*/run/credentials/*"
    "*/proc/*"
    "*environ*"
    "*AMP_API_KEY*"
    # env or printenv anywhere in a command, by any path: `env | sort`, `/usr/bin/env`.
    "/(^|[\\s;&|(`/])(env|printenv)(\\s|$|[;&|)`])/"
    # The shell builtins that print every variable when run bare, or with -p.
    "/(^|[;&|(`]\\s*)(export|set|declare|typeset)(\\s+-p)?\\s*($|[;&|)`])/"
    "*declare -p*"
    "*export -p*"
    "*typeset -p*"
    "*compgen -v*"
  ];
in
{
  imports = [ ../amp-runner.nix ];
  options.local.agentOps.networking = {
    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/ops-networking";
      readOnly = true;
      description = "The runner's GCP private key and certificate, generated on ops; it follows systemd's StateDirectory.";
    };
    runtimeDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/run/ops-networking";
      readOnly = true;
      description = "The runner's assembled GCP key file; it follows systemd's RuntimeDirectory.";
    };
    serviceAccount = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "ops-networking@infra-464520.iam.gserviceaccount.com";
    };
    keyId = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[0-9a-f]+");
      default = null;
      description = "ID of the uploaded certificate's key, the last segment of its name.";
    };
  };
  config = {
    local.ampRunner = {
      enable = true;
      hostDeploy = false;
      runnerId = "ops";
      extraPermissions =
        lib.mapAttrsToList (tool: field: {
          inherit tool;
          action = "reject";
          matches.${field} = refused;
        }) shellTools
        ++ [
          {
            tool = "*";
            action = "ask";
          }
        ];
    };
    microvm.credentialFiles."amp-runner.token" = hostToken;
    systemd.services.ops-networking-credentials = {
      description = "Generate the ops runner's GCP key once and assemble its key file";
      wantedBy = [ "multi-user.target" ];
      environment = lib.optionalAttrs gcpEnabled {
        OPS_GCP_EMAIL = cfg.serviceAccount;
        OPS_GCP_KEY_ID = cfg.keyId;
        OPS_GCP_PROJECT = config.local.agentOps.gcp.project;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        UMask = "0077";
        StateDirectory = baseNameOf cfg.stateDirectory;
        # Others may reach the 0444 certificate by name for its upload; the key stays 0400.
        StateDirectoryMode = "0711";
        RuntimeDirectory = baseNameOf cfg.runtimeDirectory;
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = true;
        ExecStart = [
          "${lib.getExe tool} generate-gcp ${cfg.stateDirectory}"
          "${lib.getExe tool} assemble ${cfg.stateDirectory} ${cfg.runtimeDirectory}"
        ];
      };
    };
    # The runner's environment does not point at the key: threads run login shells, where ops'
    # session variables point GOOGLE_APPLICATION_CREDENTIALS at the T3 agent's key instead.
    systemd.services.amp-runner = {
      wants = [ "ops-networking-credentials.service" ];
      after = [ "ops-networking-credentials.service" ];
    };
  };
}
