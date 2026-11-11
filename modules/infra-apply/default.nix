# infra-apply: plans and applies of infra/ layers from merged main, in root-owned template units
# that this host's Amp runner may start but whose credentials it cannot read
# (infra/docs/adr/2026-11-10-retire-the-ops-vm.md). The instance name is the layer and the only
# argument; `layers` below is the list of layers this host applies.
#
# - `infra-plan@<layer>` fetches main into the layer's own checkout, releases a state lock the
#   layer's runs left behind, saves `terraform plan -out` in the layer's state directory and
#   writes a summary to the journal: each change's action, address, router and the names of
#   changed attributes, never values. It reads the plan's JSON, which holds secrets unmasked, in
#   memory only.
# - `infra-apply@<layer>` fetches main again and refuses unless it is still the planned commit.
#   It refuses a plan that deletes or replaces anything without `networking:allow-destroy`, or
#   changes the firewall (local-networking's modules/bootstrap/firewall.tf) or the RouterOS user
#   module.ops_kuberack without `networking:allow-access`, on one of the PRs merged since the
#   layer's last clean apply that change it or infra/modules. The agent that opens a PR adds
#   these labels and names in its description what changes. The apply runs only the saved plan
#   on the whole layer: there is no -target and no other argument.
# - On each router a plan touches, the apply saves a backup and schedules its load after 5
#   minutes plus 15 seconds per change (at most 15), and afterwards checks that each router's
#   REST API still answers its admin user and that an IPv4 default route is active. If so, it
#   removes the job and the backup; if not, the router reloads the backup and reboots into its
#   configuration from before the apply, which the run reports loudly, as does the next run for
#   a restore nobody saw. Nothing disarms an apply that dies, so the routers restore themselves
#   then too. The checks don't cover other VLANs and their clients, DHCP, DNS, Wi-Fi, IPv6, or
#   the other site's LAN. infra/experiments/chr's deadman scenario tests the restore.
#
# The units never run code from anyone else's checkout: a Terraform configuration can run
# programs and read files as the user that plans it, so planning a checkout amp controls would
# hand amp the credentials. Each layer's units run as its own user, `infra-<layer>`, whose state
# directory holds the checkout, the GCP key and the saved plan, private to that user.
#
# An interrupted run resumes cleanly: the next run reclones a half-made checkout, resets the
# checkout to main, and releases the state lock the layer's user left behind; a saved plan that
# no longer matches the state fails as stale, and planning again starts over. Deploys neither
# stop nor restart a running unit, and the units are protected from the runner's stop and
# restart rules.
#
# The runner user starts the units with `infra-apply plan|apply|log <layer>`, which runs without
# a prompt and prints the unit's journal: they act only on what a merge decided, with
# credentials amp cannot read.
#
# One-time setup per layer, by a maintainer: apply infra/gcp-project, which creates the layer's
# service account, then upload the certificate infra-credentials-<layer> generated at boot:
#   ssh pannu sudo cat /var/lib/infra-apply/<layer>/gcp.crt > infra-<layer>.crt
#   gcloud iam service-accounts keys upload infra-<layer>.crt --iam-account <account>
# and set the layer's keyId to the last segment of the printed key name. The key expires with
# the certificate after a year: then delete gcp.key and gcp.crt there, restart
# infra-credentials-<layer>, and upload the new certificate.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.infraApply;
  layers = lib.attrNames cfg.layers;
  worker = pkgs.callPackage ./worker/package.nix { };
  layersFile = pkgs.writeText "infra-apply-layers.json" (builtins.toJSON cfg.layers);
  layerPattern = lib.concatStringsSep "|" layers;
  credentialsUnit = layer: "infra-credentials-${layer}.service";
  runUnits = lib.concatMap (layer: [
    "infra-plan@${layer}.service"
    "infra-apply@${layer}.service"
  ]) layers;
  common = {
    environment.INFRA_APPLY_LAYERS = "${layersFile}";
    serviceConfig = {
      Type = "oneshot";
      UMask = "0077";
      StateDirectory = "infra-apply/%i";
      StateDirectoryMode = "0700";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };
  run =
    verb: timeout:
    lib.recursiveUpdate common {
      description = "${verb} infra/%i from merged main";
      # Wants, not Requires: a deploy that restarts the credentials unit must not stop a run.
      wants = [
        "infra-credentials-%i.service"
        "network-online.target"
      ];
      after = [
        "infra-credentials-%i.service"
        "network-online.target"
      ];
      # A run in progress keeps going through a deploy: stopping an apply would leave the
      # routers to restore themselves, and a restart would run it again.
      restartIfChanged = false;
      stopIfChanged = false;
      path = [
        pkgs.git
        # The same nixpkgs build as infra/'s development shell.
        pkgs.terraform
      ];
      environment = {
        HOME = "/var/lib/infra-apply/%i";
        TF_IN_AUTOMATION = "1";
      };
      serviceConfig = {
        User = "infra-%i";
        Group = "infra-%i";
        ExecStart = "${lib.getExe worker} ${lib.toLower verb} %i";
        TimeoutStartSec = timeout;
        # The kernel kills these last under memory pressure: an apply killed midway leaves
        # its routers to restore themselves.
        OOMScoreAdjust = -500;
      };
    };
  command = pkgs.writeShellApplication {
    name = "infra-apply";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      usage() {
        echo 'Usage: infra-apply plan|apply|log <${lib.concatStringsSep "|" layers}>' >&2
        exit 2
      }
      [ "$#" -eq 2 ] && [[ "$2" =~ ^(${layerPattern})$ ]] || usage
      case "$1" in
      plan | apply) unit="infra-$1@$2.service" ;;
      log)
        exec journalctl --unit "infra-plan@$2.service" --unit "infra-apply@$2.service" \
          --lines 200 --no-pager --output short-iso
        ;;
      *) usage ;;
      esac
      since=$(date '+%Y-%m-%d %H:%M:%S')
      status=0
      systemctl --no-ask-password start "$unit" || status=$?
      journalctl --unit "$unit" --since "$since" --no-pager --output cat
      exit "$status"
    '';
  };
  shellTools = {
    Bash = "cmd";
    shell_command = "command";
    async_shell_command = "command";
  };
in
{
  imports = [ ../amp-runner.nix ];
  options.local.infraApply.layers = lib.mkOption {
    default = { };
    description = "The infra/ layers this host plans and applies, each with its own GCP account.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          serviceAccount = lib.mkOption {
            type = lib.types.str;
            example = "infra-local-networking@infra-464520.iam.gserviceaccount.com";
          };
          keyId = lib.mkOption {
            type = lib.types.nullOr (lib.types.strMatching "[0-9a-f]+");
            default = null;
            description = "ID of the uploaded certificate's key, the last segment of its name.";
          };
        };
      }
    );
  };
  config = lib.mkIf (layers != [ ]) {
    assertions = map (layer: {
      assertion = builtins.match "[a-z][a-z0-9-]*" layer != null;
      message = "infra-apply layer ${layer} is not a plain layer name";
    }) layers;
    users.users = lib.genAttrs (map (layer: "infra-${layer}") layers) (user: {
      isSystemUser = true;
      group = user;
    });
    users.groups = lib.genAttrs (map (layer: "infra-${layer}") layers) (_: { });
    systemd.services =
      lib.listToAttrs (
        map (
          layer:
          lib.nameValuePair "infra-credentials-${layer}" (
            lib.recursiveUpdate common {
              description = "Generate the ${layer} applier's GCP key once and write its key file";
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                User = "infra-${layer}";
                Group = "infra-${layer}";
                RemainAfterExit = true;
                StateDirectory = "infra-apply/${layer}";
                ExecStart = "${lib.getExe worker} credentials ${layer}";
              };
            }
          )
        ) layers
      )
      // {
        "infra-plan@" = run "Plan" "15min";
        "infra-apply@" = run "Apply" "30min";
      };
    security.polkit.enable = true;
    # Start only: stop and restart stay root's, so nothing interrupts a run.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id === "org.freedesktop.systemd1.manage-units" &&
            subject.user === "amp" &&
            action.lookup("verb") === "start" &&
            ${builtins.toJSON runUnits}.indexOf(action.lookup("unit")) >= 0) {
          return polkit.Result.YES;
        }
      });
    '';
    environment.systemPackages = [ command ];
    local.ampRunner = {
      # Kept out of the runner's stop, restart and reload rules.
      protectedUnits = map credentialsUnit layers ++ runUnits;
      extraPermissions = lib.mapAttrsToList (tool: field: {
        inherit tool;
        action = "allow";
        matches.${field} = [ "/^infra-apply (plan|apply|log) (${layerPattern})$/" ];
      }) shellTools;
    };
  };
}
