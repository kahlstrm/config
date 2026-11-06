# Root infrastructure credentials for the ops VM. Their private keys are generated on ops
# and never leave it; only public material is committed. Agents use them only from T3
# threads that the agents VM links at approval-required, so every command outside the
# Claude Code allow list in ./claude.nix waits for the operator.
#
# At boot, ops-credentials-keys creates, once, under /var/lib/ops-credentials (0700, on the
# persistent /var volume): a Talos client key and an os:admin CSR, and an RSA-2048 GCP key
# with a self-signed certificate. ops-credentials then assembles a talosconfig and a GCP
# service account key file in /run/ops-credentials for each service whose public half is
# committed. Both directories are outside the agent's home and project folders, so Claude
# Code asks before any read, and its managed deny rules refuse file reads there outright.
#
# Talos, from infra/local-talos on the operator machine (the os CA key stays there):
#   ssh pannu-ops cat /var/lib/ops-credentials/talos.csr > talos.csr
#   umask 077; state=$(terraform state pull)
#   os() { jq -r --arg field "$1" '.resources[] | select(.module == "module.cluster" and .type == "talos_machine_secrets")
#     | .instances[0].attributes.machine_secrets.certs.os[$field]' <<<"$state" | base64 -d; }
#   os cert > os-ca.crt && os key > os-ca.key && unset state
#   talosctl gen crt --ca os-ca --csr talos.csr --hours 8760 --name talos-client
#   cp os-ca.crt ../../modules/agent-ops/public/talos-ca.crt
#   cp talos-client.crt ../../modules/agent-ops/public/talos-client.crt
#   rm os-ca.key os-ca.crt talos.csr talos-client.crt
# The certificate expires after a year; sign a new one from the same CSR before then.
#
# GCP: the service account ops-terraform@infra-464520 for Terraform's google provider and
# GCS backend. infra/gcp-project, applied only by the operator, manages it and its grants,
# and nothing broader:
# - on bucket terraform-state-1751317459: object list, and object read/write/delete under
#   the local-talos/ prefix (state and its lock), read under local-networking/ (remote state);
# - what local-talos manages: the Workload Identity pool and its provider for the cluster
#   (roles/iam.workloadIdentityPoolAdmin) and the `local-kubernetes` Secret Manager secret's
#   metadata and IAM policy (get, update, getIamPolicy, setIamPolicy; no version access).
# The local-talos state holds the Talos machine secrets, so this key is cluster admin too.
# The key stays outside Terraform. Upload the ops key's certificate; the org policy iam.disableServiceAccountKeyUpload would block it:
#   ssh pannu-ops cat /var/lib/ops-credentials/gcp.crt > ops-gcp.crt
#   gcloud iam service-accounts keys upload ops-gcp.crt --iam-account <account>
# and set local.agentOps.gcp.{serviceAccount, keyId} in machines/ops.nix to the account
# and the last segment of the printed key name. The key expires with the certificate after
# a year: then remove gcp.key and gcp.crt on ops, run `ops-credentials generate
# /var/lib/ops-credentials` there, and upload the new certificate.
#
# Kubernetes: `ops-kubeconfig` writes the cluster-admin kubeconfig that local-talos already
# outputs, read with the GCP key, to the runtime directory, which a reboot clears. It mints
# nothing, so revoking it means rotating that credential in local-talos.
#
# Commit and deploy. To revoke, delete the committed public material and the GCP key
# (`gcloud iam service-accounts keys delete`); the Talos certificate lasts until it expires.
#
# GitHub: the operator's own account, for what the agents VM's GitHub App cannot do, such
# as PRs on repositories outside the App's owner. gh keeps its login in a directory on the
# persistent /var volume, outside the agent's folders. No process gets GH_CONFIG_DIR from
# the system: T3's server runs `gh auth token` for its own GitHub features, so each agent
# command names the directory itself and the operator sees it in the approval. Sign in
# once, interactively, as the agent user:
#   ssh -t pannu-ops GH_CONFIG_DIR=/var/lib/ops-github gh auth login --hostname github.com \
#     --git-protocol ssh --skip-ssh-key --web --insecure-storage
# The ssh protocol keeps gh from installing itself as git's credential helper, so ops' git,
# whose fetch and pull are allow-listed, stays anonymous; ops never pushes. --insecure-storage
# writes the token to hosts.yml there instead of an absent keyring. To revoke, run
# `gh auth logout` the same way, or revoke the GitHub CLI OAuth app in the account's settings.
#
# GitLab: the operator's own gitlab.com account, for issues and merge requests in upstream
# projects hosted there. glab keeps its login in /var/lib/ops-gitlab the same way, and no
# process gets GLAB_CONFIG_DIR from the system, so a future GitLab feature in T3 cannot read
# the token without approval. Create a personal access token on gitlab.com with only the
# `api` scope, which creating issues and uploading their attachments needs (`read_api` is
# read-only), and an expiry date. Sign in once, interactively, as the agent user, choosing
# token sign-in and pasting it at the masked prompt:
#   ssh -t pannu-ops GLAB_CONFIG_DIR=/var/lib/ops-gitlab glab auth login --hostname gitlab.com \
#     --git-protocol ssh --insecure-storage
# With the ssh protocol glab never offers to become git's credential helper, so ops' git stays
# anonymous. --insecure-storage writes the token to config.yml there instead of an absent
# keyring. To revoke, run `glab auth logout --hostname gitlab.com` the same way and revoke
# the token in the account's settings; to renew, sign in again with a new token.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentOps;
  inherit (config.local.agentEnvironment) user;
  settings = import ../agents/vm/ops-settings.nix;
  tool = pkgs.callPackage ./credentials-package.nix { };
  public =
    name:
    let
      file = ./public + "/${name}";
    in
    if builtins.pathExists file then file else null;
  talosEnabled = cfg.talos.caCertificate != null && cfg.talos.clientCertificate != null;
  gcpEnabled = cfg.gcp.serviceAccount != null && cfg.gcp.keyId != null;
  credentials =
    lib.optionalAttrs talosEnabled {
      talos = {
        file = "${cfg.runtimeDirectory}/talosconfig";
        environment = "TALOSCONFIG";
        access = "admin Talos API (os:admin) on every node through the talos-api-* services";
      };
    }
    // lib.optionalAttrs gcpEnabled {
      gcp = {
        file = "${cfg.runtimeDirectory}/gcp.json";
        environment = "GOOGLE_APPLICATION_CREDENTIALS";
        access = "GCP service account ${cfg.gcp.serviceAccount} for Terraform: local-talos state and the GCP resources local-talos manages";
      };
      # Read with the GCP key from local-talos' state, so it adds no access of its own.
      kubernetes = {
        file = "${cfg.runtimeDirectory}/kubeconfig";
        environment = "KUBECONFIG";
        access = "cluster-admin kubeconfig from local-talos' Terraform output, written by `ops-kubeconfig` and kept until reboot";
      };
    };
  variables = lib.mapAttrs' (
    _: credential: lib.nameValuePair credential.environment credential.file
  ) credentials;
  # Talos apid on the control planes, from the ops VM's allowed services.
  endpoints = lib.mapAttrsToList (_: service: service.address) (
    lib.filterAttrs (name: _: lib.hasPrefix "talos-api-c" name) settings.allowedServices
  );
  # Writes the admin kubeconfig from the checkout's local-talos layer; run once per boot.
  kubeconfig = pkgs.writeShellApplication {
    name = "ops-kubeconfig";
    runtimeInputs = [
      tool
      pkgs.terraform
    ];
    text = ''
      exec ops-credentials kubeconfig ${lib.escapeShellArg "${config.local.agentEnvironment.configCheckout}/infra/local-talos"} ${lib.escapeShellArg cfg.runtimeDirectory}
    '';
  };
  oneshot = {
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = user;
      UMask = "0077";
    };
  };
in
{
  imports = [
    ./claude.nix
    ./providers.nix
  ];
  options.local.agentOps = {
    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/ops-credentials";
      readOnly = true;
      description = "Private keys and their public halves, generated on ops; it follows systemd's StateDirectory.";
    };
    runtimeDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/run/ops-credentials";
      readOnly = true;
      description = "Assembled credential files; it follows systemd's RuntimeDirectory.";
    };
    githubDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/ops-github";
      readOnly = true;
      description = "gh's configuration directory, holding the operator's GitHub login.";
    };
    gitlabDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/ops-gitlab";
      readOnly = true;
      description = "glab's configuration directory, holding the operator's GitLab login.";
    };
    talos = {
      caCertificate = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = public "talos-ca.crt";
        description = "Talos os CA certificate (PEM); null until committed under ./public.";
      };
      clientCertificate = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = public "talos-client.crt";
        description = "The os:admin certificate the operator signed for ops' CSR (PEM).";
      };
    };
    gcp = {
      project = lib.mkOption {
        type = lib.types.str;
        default = "infra-464520";
      };
      serviceAccount = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "ops-terraform@infra-464520.iam.gserviceaccount.com";
      };
      keyId = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[0-9a-f]+");
        default = null;
        description = "ID of the uploaded certificate's key, the last segment of its name.";
      };
    };
  };
  config = {
    environment.systemPackages = with pkgs; [
      talosctl
      # The same nixpkgs build as infra/'s development shell.
      terraform
      kubectl
      glab
      tool
    ]
    ++ lib.optional gcpEnabled kubeconfig;
    systemd.tmpfiles.rules = map (directory: "d ${directory} 0700 ${user} users -") [
      cfg.githubDirectory
      cfg.gitlabDirectory
    ];
    systemd.services.ops-credentials-keys = lib.recursiveUpdate oneshot {
      description = "Generate ops' infrastructure private keys and their public halves, once";
      wantedBy = [ "multi-user.target" ];
      environment.OPS_TALOS_CLIENT_IP = settings.network.guestAddress;
      serviceConfig = {
        StateDirectory = baseNameOf cfg.stateDirectory;
        StateDirectoryMode = "0700";
        ExecStart = "${lib.getExe tool} generate ${cfg.stateDirectory}";
      };
    };
    systemd.services.ops-credentials = lib.recursiveUpdate oneshot {
      description = "Assemble ops' infrastructure credentials from local keys and committed public material";
      wantedBy = [ "multi-user.target" ];
      requires = [ "ops-credentials-keys.service" ];
      after = [ "ops-credentials-keys.service" ];
      environment =
        lib.optionalAttrs talosEnabled {
          OPS_TALOS_CA = "${cfg.talos.caCertificate}";
          OPS_TALOS_CRT = "${cfg.talos.clientCertificate}";
          OPS_TALOS_ENDPOINTS = lib.concatStringsSep " " endpoints;
        }
        // lib.optionalAttrs gcpEnabled {
          OPS_GCP_EMAIL = cfg.gcp.serviceAccount;
          OPS_GCP_KEY_ID = cfg.gcp.keyId;
          OPS_GCP_PROJECT = cfg.gcp.project;
        };
      serviceConfig = {
        RuntimeDirectory = baseNameOf cfg.runtimeDirectory;
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = true;
        ExecStart = "${lib.getExe tool} assemble ${cfg.stateDirectory} ${cfg.runtimeDirectory}";
      };
    };
    systemd.services.t3code = {
      wants = [ "ops-credentials.service" ];
      after = [ "ops-credentials.service" ];
      environment = variables;
    };
    environment.sessionVariables = variables;
    local.agentEnvironment.credentials =
      lib.mapAttrs (
        _: credential:
        credential
        // {
          access = "${credential.access}; private key generated on ops; every use outside the Claude Code allow list needs operator approval in T3";
        }
      ) credentials
      // {
        github = {
          file = "${cfg.githubDirectory}/hosts.yml";
          access = "the operator's GitHub account, once they sign in with gh auth login, for what the agents VM's GitHub App cannot do, such as PRs on repositories outside its owner; nothing sets GH_CONFIG_DIR, so run `GH_CONFIG_DIR=${cfg.githubDirectory} gh ...`; every command needs operator approval in T3";
        };
        gitlab = {
          file = "${cfg.gitlabDirectory}/config.yml";
          access = "the operator's gitlab.com account (token scope api), once they sign in with glab auth login, for issues and merge requests in projects hosted on gitlab.com; nothing sets GLAB_CONFIG_DIR, so run `GLAB_CONFIG_DIR=${cfg.gitlabDirectory} glab ...`; every command needs operator approval in T3";
        };
      };
  };
}
