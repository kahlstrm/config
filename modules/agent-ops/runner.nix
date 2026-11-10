# The ops runner: an Amp runner in the ops VM for privileged work, starting with applies of
# infra/local-networking (infra/docs/adr/2026-11-09-privileged-work-on-the-ops-runner.md).
#
# It runs as amp, not as the agent user, so nothing under /home/agent loads into its threads,
# including the personal instructions linked there, and it cannot read the T3 agent's
# credentials. It holds only what local-networking applies and secret edits need: its own GCP
# key for the service account `networking.serviceAccount`, which may write local-networking's
# state, read the `local-networking` Secret Manager secret with the RouterOS credentials, and
# add versions to it and to `local-kubernetes`. infra/gcp-project grants that, applied from a
# maintainer's machine, never from ops.
#
# It asks before every tool call, file reads and shell commands included, and refuses
# commands that name its credentials or print environments, which hold the Amp key. The
# rules guide the agent; approvals are the boundary, since any approved command runs as amp
# and can read what amp can.
#
# `ops-networking` (./networking) does the work, with the runner's GCP key, which it passes to
# Terraform itself (the runner's login shells point GOOGLE_APPLICATION_CREDENTIALS elsewhere).
# Each run is one approval, and the prompt shows what it does:
#
# - `ops-networking plan --pr N`, in a clean checkout at origin/main that contains merged PR
#   N: releases a state lock this runner left behind (a deploy of ops restarts it mid-run),
#   saves `terraform plan -out` in the runtime directory and prints a summary for the thread
#   and the PR: each change's action, address, router and the names of changed attributes,
#   never values. It reads the plan's JSON, which holds secrets unmasked, in memory only.
# - `ops-networking apply` reads the PR's labels again and refuses a plan that deletes or
#   replaces anything without `networking:allow-destroy`, or changes the firewall
#   (modules/bootstrap/firewall.tf) or ops' own RouterOS user (module.ops_kuberack) without
#   `networking:allow-access`. Only labels a person added count, not an app's. Then, on each
#   router the plan touches, it saves a backup and schedules its load after 5 minutes plus
#   15 seconds per change (at most 15), applies only the saved plan file, and checks that
#   each router's REST API still answers its admin user and that an IPv4 default route is
#   active. If so, it removes the job and the backup; if not, the router reloads the backup
#   and reboots into its configuration from before the apply, which the run reports loudly,
#   as does the next run for a restore nobody saw. The state then has drift, fixed forward with a new plan.
#   Nothing disarms a runner that dies mid-apply, so the routers restore themselves then too.
#   The checks don't cover what ops can't see from its REST path: other VLANs and their
#   clients, DHCP, DNS, Wi-Fi, IPv6, or the other site's LAN. A change that breaks only those
#   is kept. The backups are unencrypted on the routers' flash for those minutes and are never
#   printed. infra/experiments/chr's deadman scenario tests the restore.
# - `ops-networking secret-edit SECRET --remove PATH --generate PATH=token|password
#   --from-env PATH=VARIABLE …` writes a new version of the `local-networking` or
#   `local-kubernetes` Secret Manager secret, changing the named JSON properties. The prompt
#   and output show the secret and property names, never values: generated values are made on
#   ops and never printed, and --from-env reads a variable of the runner's environment. That
#   holds a value only a maintainer has, set as a personal Amp secret through Amp's masked
#   dialog, only if the runner runs with Amp's Secrets & Env Vars (`--amp-env`), which it
#   doesn't: that would put every personal and project Amp secret in its threads' shells.
#   Without it, a maintainer sets such values with `just edit`.
#
# One-time setup by a maintainer:
#
# 1. Register the runner's key. Create an Amp access token for the runner in Amp's security
#    settings (https://ampcode.com/settings/security; it starts with `sgamp_`). It is committed
#    encrypted with sops to ops' SSH host key alone (hosts."pannu-ops" in lib/ssh-keys.nix),
#    not to the repository-wide keys, as ./amp-runner-token.sops.yaml, and sops-nix decrypts
#    it on ops at boot into a file only root reads, which systemd passes to the runner as a
#    credential. Encrypting needs only the public key in .sops.yaml, so any checkout with sops
#    will do. From the repository root, paste the key at the silent prompt:
#      read -rsp 'Amp access token: ' token && printf 'token: %s\n' "$token" |
#        nix run nixpkgs#sops -- encrypt --filename-override modules/agent-ops/amp-runner-token.sops.yaml \
#          --output modules/agent-ops/amp-runner-token.sops.yaml /dev/stdin; unset token
#    Commit the file and deploy pannu, which restarts ops into its new image; the runner then
#    shows as `ops` in Amp's runner list. To replace the key, encrypt a new one the same way.
#    To revoke, delete the key in Amp and the file here.
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
  networking = pkgs.callPackage ./networking/package.nix {
    inherit (cfg) runtimeDirectory;
    inherit (config.local.agentOps.gcp) project;
  };
  user = "amp";
  # The runner's Amp access key; until it is committed, the runner does not start.
  tokenSecret = ./amp-runner-token.sops.yaml;
  hasToken = builtins.pathExists tokenSecret;
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
    environment.systemPackages = [ networking ];
    local.ampRunner.tokenFile = lib.mkIf hasToken config.sops.secrets.amp-runner-token.path;
    # Owned by root, so only systemd reads it, for the runner's credential.
    sops.secrets.amp-runner-token = lib.mkIf hasToken {
      sopsFile = tokenSecret;
      key = "token";
    };
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
