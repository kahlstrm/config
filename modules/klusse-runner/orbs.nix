# Self-hosted Amp orbs in a klusse runner VM, as Docker containers
# (infra/docs/adr/2026-11-19-docker-orbs-in-runner-vms.md). `amp orb provider` connects out to
# Amp and runs ./orb-dispatch.sh for each spawn, pause and delete job. An orb is one container
# of Amp's orb image: pausing stops it and keeps its files, and its processes end.
#
# The VM provisions the provider itself. On its first start the service creates the provider in
# the account with the Amp access key the runner uses, which saves the provider's token in the
# service's state directory, and makes it the account's default orb. Should that state be lost,
# delete the provider under Settings → Orbs in Amp, and the next start creates it again.
# With `workspace`, a second service does the same for a provider of the account's workspace.
#
# Orbs are privileged containers, so that Docker and KVM work inside them: root in an orb is
# root in the VM, as for the runner's threads, and the VM stays the boundary. Docker keeps its
# data on the disk `orbs`, apart from the runner's /nix and /home, formatted as XFS with project
# quotas so each orb's files are capped. Without that disk Docker and the provider stay down.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  runner = config.local.klusseRunner;
  cfg = runner.orbs;
  user = "amp-orbs";
  dockerRoot = "/var/lib/docker";
  credential = "amp-access-key";
  amp = lib.getExe config.local.ampRunner.package;
  label = "amp-orb";
  dispatch = pkgs.writeShellApplication {
    name = "orb-dispatch";
    runtimeInputs = [
      config.virtualisation.docker.package
      config.systemd.package
      pkgs.coreutils
      pkgs.gnused
      pkgs.gnutar
    ];
    runtimeEnv = {
      ORB_LABEL = label;
      ORB_BOOTSTRAP_LOG = "/tmp/amp-orb-bootstrap.log";
      ORB_CPUS = toString cfg.cpus;
      ORB_MEMORY = cfg.memory;
    };
    text = builtins.readFile ./orb-dispatch.sh;
  };
  # A spawn must not wait for the image: the first pull takes minutes.
  ensureImage = pkgs.writeShellApplication {
    name = "amp-orb-ensure-image";
    runtimeInputs = [ config.virtualisation.docker.package ];
    text = ''
      docker image inspect ${lib.escapeShellArg cfg.image} > /dev/null 2>&1 ||
        docker pull --quiet ${lib.escapeShellArg cfg.image}
    '';
  };
  # The account's own provider, and one for its workspace: each has its own token, in its own
  # state directory, and both start orbs in the same Docker.
  providers = {
    amp-orb-provider = {
      state = "amp-orbs";
      provider = cfg.name;
      scope = "";
      of = "the account";
    };
  }
  // lib.optionalAttrs cfg.workspace {
    amp-orb-provider-workspace = {
      state = "amp-orbs-workspace";
      # Its own name: where both are visible, Amp picks the workspace's provider by name.
      provider = "${cfg.name}-workspace";
      scope = " --workspace";
      of = "the workspace";
    };
  };
  provider =
    name:
    {
      provider,
      scope,
      of,
      ...
    }:
    pkgs.writeShellApplication {
      inherit name;
      text = ''
        # Each step once: the markers say this state directory holds the provider's token, and
        # that the provider was made the default.
        AMP_API_KEY="$(< "$CREDENTIALS_DIRECTORY/${credential}")"
        export AMP_API_KEY
        if [ ! -e "$HOME/provider-created" ]; then
          if ! ${amp} orb provider create ${lib.escapeShellArg provider}${scope}; then
            echo "Could not create the orb provider ${provider} of ${of}. If it exists in Amp, delete it under Settings → Orbs." >&2
            exit 1
          fi
          touch "$HOME/provider-created"
        fi
        ${lib.optionalString cfg.default ''
          if [ ! -e "$HOME/provider-default" ]; then
            if ${amp} orb provider set-default ${lib.escapeShellArg provider}${scope}; then
              touch "$HOME/provider-default"
            else
              echo "Could not make ${provider} the default orb of ${of}; the next start tries again" >&2
            fi
          fi
        ''}
        unset AMP_API_KEY
        exec ${amp} orb provider ${lib.getExe dispatch}
      '';
    };
  reap = pkgs.writeShellApplication {
    name = "amp-orb-reap";
    runtimeInputs = [
      config.virtualisation.docker.package
      pkgs.coreutils
    ];
    text = ''
      # Amp sends no delete job for an archived thread, so stopped orbs would pile up.
      cutoff=$(date -d '${toString cfg.keepDays} days ago' +%s)
      for orb in $(docker ps -aq --filter label=${label} --filter status=exited); do
        finished=$(docker inspect --format '{{.State.FinishedAt}}' "$orb")
        if [ "$(date -d "$finished" +%s)" -lt "$cutoff" ]; then
          docker rm --volumes "$orb"
        fi
      done
      # Project snapshots no orb uses any more, and the images a newer pull replaced.
      docker image prune --all --force --filter label=${label}-snapshot --filter until=${toString (cfg.keepDays * 24)}h
      docker image prune --force
    '';
  };
in
{
  options.local.klusseRunner.orbs = {
    enable = lib.mkEnableOption "self-hosted Amp orbs as Docker containers in this VM";
    name = lib.mkOption {
      type = lib.types.strMatching "[a-z0-9]([a-z0-9-]*[a-z0-9])?";
      default = config.networking.hostName;
      description = "The orb provider's name in Amp, which threads pick it by.";
    };
    default = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether a provider becomes the default orb, of the account or of its workspace, when it is created.";
    };
    workspace = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether the VM also runs a provider for the account's workspace, `<name>-workspace`, so
        its members' threads run in orbs here. Their orbs have root in this VM, like the
        account's own, and can read the account's Amp access key. The account must be an admin
        of the workspace.
      '';
    };
    image = lib.mkOption {
      type = lib.types.str;
      default = "us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb:latest";
      description = "The image new orbs start from. The provider pulls it before its first start and a timer daily, so no spawn waits for a pull.";
    };
    cpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "CPUs one orb may use.";
    };
    memory = lib.mkOption {
      type = lib.types.str;
      default = "8g";
      description = "Memory one orb may use. A limit, not a reservation.";
    };
    diskLimit = lib.mkOption {
      type = lib.types.str;
      default = "30G";
      description = "Size of the files one orb may add to its image.";
    };
    keepDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Days a stopped orb, or an image no orb uses, is kept before it is removed.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        boot.supportedFilesystems = [ "xfs" ];
        fileSystems.${dockerRoot} = {
          device = "/dev/disk/by-id/virtio-orbs";
          fsType = "xfs";
          autoFormat = true;
          options = [
            "pquota"
            "nofail"
            "x-systemd.device-timeout=15s"
            "x-systemd.growfs"
          ];
        };

        virtualisation.docker = {
          enable = true;
          daemon.settings = {
            # The per-container size limit needs the overlay2 driver on XFS with project quotas.
            features.containerd-snapshotter = false;
            storage-driver = "overlay2";
            storage-opts = [ "overlay2.size=${cfg.diskLimit}" ];
            dns = runner.resolvers;
          };
        };
        # After the disk is formatted and mounted, and never on the runner's claim, which a
        # missing disk would leave under Docker's directory. The provider and the timers' services
        # require Docker, so they stay down with it.
        systemd.services.docker.unitConfig.RequiresMountsFor = dockerRoot;

        # The guest firewall's layer for orbs, whose traffic is forwarded: as for the VM itself,
        # DNS to the resolvers and public HTTP and HTTPS. Root in an orb can lift it; the cluster's
        # policy is the boundary.
        networking.nftables.tables.runner-egress.content = ''
          chain forward {
            type filter hook forward priority filter; policy drop;
            ct state established,related accept
            ip daddr { ${lib.concatStringsSep ", " runner.resolvers} } meta l4proto { tcp, udp } th dport 53 accept
            ip daddr != { ${lib.concatStringsSep ", " runner.privateRanges} } tcp dport { 80, 443 } accept
            meta l4proto tcp reject with tcp reset
            reject
          }
        '';

        users.groups.${user} = { };
        users.users.${user} = {
          isSystemUser = true;
          group = user;
          home = "/var/lib/amp-orbs";
          extraGroups = [ "docker" ];
        };

        systemd.services.amp-orb-image = {
          description = "Pull the image new orbs start from";
          requires = [ "docker.service" ];
          after = [
            "docker.service"
            "network-online.target"
          ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe config.virtualisation.docker.package} pull --quiet ${cfg.image}";
          };
        };
        systemd.timers.amp-orb-image = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "1min";
            OnUnitActiveSec = "1d";
          };
        };

        # The console is the VM's only log the cluster keeps, and a dispatch program's output
        # does not reach it.
        systemd.services.amp-orb-log = {
          description = "Copy what orbs' bootstraps said to the console";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = "${config.systemd.package}/bin/journalctl --follow --lines 0 --output cat --identifier ${label}-bootstrap";
            StandardOutput = "journal+console";
            Restart = "always";
            RestartSec = 30;
          };
        };

        systemd.services.amp-orb-reap = {
          description = "Remove orbs stopped for ${toString cfg.keepDays} days and unused images";
          requires = [ "docker.service" ];
          after = [ "docker.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe reap;
          };
        };
        systemd.timers.amp-orb-reap = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "daily";
            Persistent = true;
          };
        };
      }
      {
        systemd.services = lib.mapAttrs (name: settings: {
          description = "Amp orb provider ${settings.provider} of ${settings.of}";
          wantedBy = [ "multi-user.target" ];
          requires = [
            "runner-isolation-check.service"
            "docker.service"
          ];
          after = [
            "runner-isolation-check.service"
            "docker.service"
          ];
          unitConfig.ConditionPathExists = toString config.local.ampRunner.tokenFile;
          environment = {
            HOME = "/var/lib/${settings.state}";
            ORB_IMAGE = cfg.image;
          };
          serviceConfig = {
            User = user;
            Group = user;
            ExecStartPre = lib.getExe ensureImage;
            ExecStart = lib.getExe (provider name settings);
            LoadCredential = [ "${credential}:${config.local.ampRunner.tokenFile}" ];
            StateDirectory = settings.state;
            StateDirectoryMode = "0700";
            WorkingDirectory = "/var/lib/${settings.state}";
            # The first start pulls the image, within this time.
            TimeoutStartSec = "30min";
            Restart = "always";
            RestartSec = 30;
            # On the console too, which the cluster keeps as the VM's log.
            StandardOutput = "journal+console";
            StandardError = "journal+console";
          };
        }) providers;
      }
    ]
  );
}
