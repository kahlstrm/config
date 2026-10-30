# Root infrastructure credentials for the ops VM, each active once its secret is enrolled.
# Agents use them only from T3 threads that the agents VM links at approval-required, so
# every command outside the Claude Code allow list in ./claude.nix waits for the operator.
# agenix decrypts to /run/agenix, outside the ops user's home and project folders, where
# Claude Code asks before any read and the managed deny rules refuse file reads outright.
#
# First add the ops VM's host key, from `ssh pannu-ops cat /var/lib/ssh/ssh_host_ed25519_key.pub`,
# as hosts."pannu-ops" in lib/ssh-keys.nix, and these rules to secrets/secrets.nix:
#   "ops-talosconfig.age".publicKeys = sshKeys.administrators ++ [ sshKeys.hosts."pannu-ops" ];
#   "ops-gcp-credentials.age".publicKeys = sshKeys.administrators ++ [ sshKeys.hosts."pannu-ops" ];
#
# Talos: an admin client config for talosctl, using the talos-api-* addresses from
# modules/agents/vm/ops-settings.nix. From the repository root, with an admin talosconfig:
#   talosctl -n 10.10.10.11 config new --roles os:admin --crt-ttl 8760h ops-talosconfig
#   talosctl --talosconfig ops-talosconfig config endpoint 10.10.10.11 10.10.10.12 10.10.10.13
#   talosctl --talosconfig ops-talosconfig config node 10.10.10.11
#   (cd secrets && agenix --edit ops-talosconfig.age) < ops-talosconfig && rm ops-talosconfig
# The client certificate expires after a year; re-enroll before then.
#
# GCP: a service account key for Terraform's google provider and GCS backend, in project
# infra-464520. Grant it, and nothing broader:
# - on bucket terraform-state-1751317459: object list, and object read/write/delete under
#   the local-talos/ prefix (state and its lock), read under local-networking/ (remote state);
# - what local-talos manages: the Workload Identity pool and its provider for the cluster
#   (roles/iam.workloadIdentityPoolAdmin) and the `local-kubernetes` Secret Manager secret's
#   metadata and IAM policy (get, update, getIamPolicy, setIamPolicy; no version access).
# The local-talos state holds the Talos machine secrets, so this key is cluster admin too.
#   gcloud iam service-accounts keys create ops-gcp-credentials --iam-account <account>
#   (cd secrets && agenix --edit ops-gcp-credentials.age) < ops-gcp-credentials && rm ops-gcp-credentials
#
# Commit each secret and deploy. Delete a secret, and the key or certificate behind it, to revoke.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentOps;
  inherit (config.local.agentEnvironment) user;
  credentials = {
    talos = {
      secret = "ops-talosconfig";
      variable = "TALOSCONFIG";
      access = "admin Talos API (os:admin) on every node through the talos-api-* services";
    };
    gcp = {
      secret = "ops-gcp-credentials";
      variable = "GOOGLE_APPLICATION_CREDENTIALS";
      access = "GCP service account for Terraform: local-talos state and the GCP resources local-talos manages";
    };
  };
  repositorySecret =
    credential:
    let
      file = ../../secrets + "/${credential.secret}.age";
    in
    if builtins.pathExists file then file else null;
  enrolled = lib.filterAttrs (name: _: cfg.secretFiles.${name} != null) credentials;
  path = credential: config.age.secrets.${credential.secret}.path;
  variables = lib.mapAttrs' (
    _: credential: lib.nameValuePair credential.variable (path credential)
  ) enrolled;
in
{
  imports = [ ./claude.nix ];
  options.local.agentOps.secretFiles = lib.mkOption {
    type = lib.types.attrsOf (lib.types.nullOr lib.types.path);
    default = lib.mapAttrs (_: repositorySecret) credentials;
    defaultText = lib.literalMD "the enrolled `secrets/<secret>.age` file, or null";
    description = "Encrypted credential per service; null leaves the service unprovisioned.";
  };
  config = {
    environment.systemPackages = with pkgs; [
      talosctl
      # The same nixpkgs build as infra/'s development shell.
      terraform
      kubectl
    ];
    age.secrets = lib.mapAttrs' (
      name: credential:
      lib.nameValuePair credential.secret {
        file = cfg.secretFiles.${name};
        owner = user;
        mode = "0400";
      }
    ) enrolled;
    environment.sessionVariables = variables;
    systemd.services.t3code.environment = variables;
    local.agentEnvironment.credentials = lib.mapAttrs (_: credential: {
      file = path credential;
      environment = credential.variable;
      access = "${credential.access}; every use outside the Claude Code allow list needs operator approval in T3";
    }) enrolled;
  };
}
