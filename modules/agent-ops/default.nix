# Root infrastructure credentials for the ops VM. Their private keys are generated on ops
# and never leave it; only public material is committed. Agents use them only from T3
# threads that the agents VM links at approval-required, so every command outside the
# Claude Code allow list in ./claude.nix waits for the operator, unless the operator raises
# the thread to Auto.
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
# RouterOS: `ops-routeros` writes a netrc for kuberack's RouterOS user `ops` to the runtime
# directory from infra/local-networking's `ops_routeros_password` output, which the GCP key
# reads like local-talos' remote state does. The user may only read over the REST API and
# run the PoE power-cycle scripts that layer declares (`ops-poe-cycle-<node>`), and ops
# reaches kuberack's HTTPS port alone, through the kuberack-rest service. Nothing to enroll:
# applying local-networking creates the user, and a new password reaches ops on its next
# `ops-routeros`. To revoke, remove the user from local-networking.
#
# Deployments: an SSH key for the ops-deploy account that pannu, zima and poenttoe create
# (modules/ops-deploy.nix). Its forced command only queues a deployment of merged upstream
# main for that machine's own configuration, or reports its status and log, so the key
# chooses when a merged change lands, not what lands. Ops' SSH config names the machines,
# so `ssh pannu deploy` queues one and `ssh pannu status` follows it. Commit the public half:
#   ssh pannu-ops cat /var/lib/ops-credentials/deploy.pub
# into `deployers.ops` in lib/ssh-keys.nix, together with any machine's host key missing
# from `hosts` there (`ssh zima cat /etc/ssh/ssh_host_ed25519_key.pub`), and deploy each
# machine once by hand (`make deploy-<machine>`) so its ops-deploy account trusts the key.
# To revoke, remove the key from `deployers.ops` and deploy the machines.
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
#
# Bambuddy: an API key for the Bambuddy on pannu, which ops reaches through the bambuddy
# service, a port of pannu's that serves Bambuddy alone and only to ops. The key may only
# manage the library, where it uploads and slices files, and read status; without queue or
# printer control it cannot start a print, which the operator does in Bambuddy. Its
# permissions hold only while Bambuddy's authentication is on; with it off, Bambuddy
# accepts every request. Create the key in Bambuddy's settings with only "Manage library"
# and "Read status", then store it once, as the agent user, pasting it at the silent prompt:
#   ssh -t pannu-ops 'umask 077; read -rsp "API key: " key && printf "X-API-Key: %s\n" "$key" > /var/lib/ops-bambuddy/header'
# To revoke, delete the key in Bambuddy and the file on ops.
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
  sshKeys = import ../../lib/ssh-keys.nix;
  deployKey = "${cfg.stateDirectory}/deploy.key";
  # Host keys come from lib/ssh-keys.nix; a machine without one there refuses to connect.
  knownTargets = lib.filterAttrs (
    _: target: sshKeys.hosts ? ${target.hostKey}
  ) settings.deployTargets;
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
        access = "admin Talos API (os:admin) on every node through the talos-api-* services; private key generated on ops";
      };
    }
    // lib.optionalAttrs gcpEnabled {
      gcp = {
        file = "${cfg.runtimeDirectory}/gcp.json";
        environment = "GOOGLE_APPLICATION_CREDENTIALS";
        access = "GCP service account ${cfg.gcp.serviceAccount} for Terraform: local-talos state and the GCP resources local-talos manages; private key generated on ops";
      };
      # Read with the GCP key from local-talos' state, so it adds no access of its own.
      kubernetes = {
        file = "${cfg.runtimeDirectory}/kubeconfig";
        environment = "KUBECONFIG";
        access = "cluster-admin kubeconfig from local-talos' Terraform output, written by `ops-kubeconfig` and kept until reboot";
      };
      # Read with the GCP key from local-networking's state.
      routeros = {
        file = "${cfg.runtimeDirectory}/routeros.netrc";
        access = "kuberack's RouterOS user `ops` over REST (https://${routerosHost}, at ${settings.allowedServices.kuberack-rest.address}): read, and run the `ops-poe-cycle-<node>` scripts; written by `ops-routeros` and kept until reboot; use as `curl --netrc-file ${cfg.runtimeDirectory}/routeros.netrc --resolve ${routerosHost}:443:${settings.allowedServices.kuberack-rest.address}`";
      };
    };
  # The netrc has no environment variable; commands name it.
  variables = lib.mapAttrs' (
    _: credential: lib.nameValuePair credential.environment credential.file
  ) (lib.filterAttrs (_: credential: credential ? environment) credentials);
  # Talos apid on the control planes, from the ops VM's allowed services.
  endpoints = lib.mapAttrsToList (_: service: service.address) (
    lib.filterAttrs (name: _: lib.hasPrefix "talos-api-c" name) settings.allowedServices
  );
  routerosHost = "kuberack.networking.kalski.xyz";
  bambuddy = import ../agents/vm/bambuddy-endpoint.nix;
  # A command that writes a credential from a layer of the checkout's infra/ with the GCP
  # key; each runs once per boot of ops.
  fromLayer =
    name: command: layer: extra:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        tool
        pkgs.terraform
      ];
      text = ''
        exec ops-credentials ${command} ${
          lib.escapeShellArgs (
            [
              "${config.local.agentEnvironment.configCheckout}/infra/${layer}"
              cfg.runtimeDirectory
            ]
            ++ extra
          )
        }
      '';
    };
  kubeconfig = fromLayer "ops-kubeconfig" "kubeconfig" "local-talos" [ ];
  routeros = fromLayer "ops-routeros" "routeros" "local-networking" [ routerosHost ];
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
    bambuddyDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/ops-bambuddy";
      readOnly = true;
      description = "Holds the operator-stored Bambuddy API key as a curl header file.";
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
    environment.systemPackages =
      with pkgs;
      [
        talosctl
        # The same nixpkgs build as infra/'s development shell.
        terraform
        kubectl
        glab
        tool
      ]
      ++ lib.optionals gcpEnabled [
        kubeconfig
        routeros
      ];
    programs.ssh.knownHosts = lib.mapAttrs' (
      _: target: lib.nameValuePair target.hostKey { publicKey = sshKeys.hosts.${target.hostKey}; }
    ) knownTargets;
    programs.ssh.extraConfig = lib.concatStrings (
      lib.mapAttrsToList (name: target: ''
        Host ${name}
          HostName ${target.address}
          HostKeyAlias ${target.hostKey}
          User ops-deploy
          IdentityFile ${deployKey}
          IdentitiesOnly yes
          StrictHostKeyChecking yes
          BatchMode yes
          RequestTTY no
      '') settings.deployTargets
    );
    systemd.tmpfiles.rules = map (directory: "d ${directory} 0700 ${user} users -") [
      cfg.githubDirectory
      cfg.gitlabDirectory
      cfg.bambuddyDirectory
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
    # The agent checks a task and each command before running it; see ./instructions.md.
    local.agentEnvironment.extraInstructions = [ ./instructions.md ];
    local.agentEnvironment.credentials =
      lib.mapAttrs (
        _: credential:
        credential
        // {
          access = "${credential.access}; every use outside the Claude Code allow list needs operator approval in T3";
        }
      ) credentials
      // {
        deploy = {
          file = deployKey;
          access = "SSH key for the ops-deploy account on ${lib.concatStringsSep ", " (lib.attrNames settings.deployTargets)}, once its public half is committed: `ssh <machine> deploy` queues a deployment of merged upstream main to that machine, `ssh <machine> status` and `ssh <machine> log` follow it, and nothing else runs there; deploy needs operator approval in T3";
        };
        github = {
          file = "${cfg.githubDirectory}/hosts.yml";
          access = "the operator's GitHub account, once they sign in with gh auth login, for what the agents VM's GitHub App cannot do, such as PRs on repositories outside its owner; nothing sets GH_CONFIG_DIR, so run `GH_CONFIG_DIR=${cfg.githubDirectory} gh ...`; every command needs operator approval in T3";
        };
        bambuddy = {
          file = "${cfg.bambuddyDirectory}/header";
          access = "a Bambuddy API key that may upload and slice files in Bambuddy's library and read status, not queue or control the printer, once the operator stores it; use as `curl -H @${cfg.bambuddyDirectory}/header https://${bambuddy.name}:${toString bambuddy.port}/api/v1/...`; every command needs operator approval in T3";
        };
        gitlab = {
          file = "${cfg.gitlabDirectory}/config.yml";
          access = "the operator's gitlab.com account (token scope api), once they sign in with glab auth login, for issues and merge requests in projects hosted on gitlab.com; nothing sets GLAB_CONFIG_DIR, so run `GLAB_CONFIG_DIR=${cfg.gitlabDirectory} glab ...`; every command needs operator approval in T3";
        };
      };
  };
}
