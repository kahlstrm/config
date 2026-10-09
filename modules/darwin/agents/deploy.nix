{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentHost.deploy;
  user = config.system.primaryUser;
  darwin-rebuild = config.system.build.darwin-rebuild;
  nix = config.nix.package;
  tailscale = config.services.tailscale.package;

  # Activation runs as the launchd job org.nixos.darwin-deploy, outside the
  # caller's process tree: a deploy that restarts T3 kills an agent session
  # (and its `sudo darwin-deploy`) but not the job.
  state = "/var/lib/darwin-deploy";
  log = "/var/log/darwin-deploy.log";
  job = "org.nixos.darwin-deploy";

  # Switches to the system the front end built and activates it: the only
  # part that can restart T3. Ends by writing "<request id> <status> <time>"
  # to the result file.
  deployJob = pkgs.writeShellApplication {
    name = "darwin-deploy-job";
    text = ''
      export HOME=/var/root
      read -r id action config rev system <${state}/request
      finish() {
        echo "$id $1 $(date '+%FT%T')" >${state}/result.tmp && mv ${state}/result.tmp ${state}/result
        echo "darwin-deploy[$id]: finished with status $1 at $(date '+%F %T')"
        exit "$1"
      }
      echo "darwin-deploy[$id]: $action $config $rev at $(date '+%F %T')"

      # Activate in the user's login session like a terminal would: nix-darwin
      # removes user agents with a bare `launchctl unload`, which from a system
      # job targets the wrong domain and silently leaves them running.
      in_session() { /bin/launchctl asuser "$(id -u ${user})" "$@"; }

      if [ "$action" = rollback ]; then
        if in_session ${darwin-rebuild}/bin/darwin-rebuild --rollback; then finish 0; else finish 1; fi
      fi
      [[ "$action" = switch && "$system" =~ ^/nix/store/[a-z0-9]{32}-darwin-system-[^/]+$ ]] || finish 2
      [ -x "$system/activate" ] || finish 2
      ${nix}/bin/nix-env -p ${config.system.profile} --set "$system" || finish 1
      in_session "$system/activate" || finish 1
      finish 0
    '';
  };

  # Builds the committed HEAD of the local checkout (never the working tree)
  # and pushes it, both in the caller's login session (git uses the user's
  # keychain), then hands activation to the job and follows its log.
  deploy = pkgs.writeShellApplication {
    name = "darwin-deploy";
    text = ''
      die() { echo "darwin-deploy: $*" >&2; exit 2; }
      usage="usage: sudo darwin-deploy [--rollback${
        lib.optionalString (cfg.variants != [ ]) " | --variant <${lib.concatStringsSep "|" cfg.variants}>"
      }]"
      [ "$(id -u)" -eq 0 ] || die "run with sudo"
      export HOME=/var/root # sudo keeps the caller's HOME; root's nix commands warn about it
      as_user() { sudo -u ${user} -H -- "$@"; }
      git() { as_user ${lib.getExe pkgs.git} -C ${lib.escapeShellArg cfg.repository} "$@"; }

      action=switch config=${lib.escapeShellArg cfg.configuration} rev=- system=-
      case "$#:''${1-}" in
        0:) ;;
        1:--rollback) action=rollback ;;
        ${lib.optionalString (cfg.variants != [ ]) ''
          2:--variant)
            case "$2" in
              ${lib.concatStringsSep "|" cfg.variants}) config="$config-$2" ;;
              *) die "unknown variant '$2'; $usage" ;;
            esac
            ;;
        ''}
        *) die "$usage" ;;
      esac
      if /bin/launchctl print system/${job} 2>/dev/null | grep -q 'state = running'; then
        die "another deploy is running; follow ${log}"
      fi

      if [ "$action" = switch ]; then
        [ -z "$(git status --porcelain)" ] || die "uncommitted changes in ${cfg.repository}; commit first"
        rev=$(git rev-parse HEAD)
        echo "darwin-deploy: building $config at $rev" >&2
        system=$(as_user ${nix}/bin/nix build --no-link --print-out-paths \
          "git+file://${cfg.repository}?rev=$rev#darwinConfigurations.$config.system") || die "build failed"
        if git push --quiet origin "$rev:refs/heads/main"; then
          echo "darwin-deploy: pushed $rev to origin/main" >&2
        else
          echo "darwin-deploy: WARNING: could not push $rev to origin/main" >&2
        fi
      fi

      id="$(date +%s)-$$"
      mkdir -p ${state}
      echo "$id $action $config $rev $system" >${state}/request.tmp && mv ${state}/request.tmp ${state}/request
      offset=$(stat -f %z ${log} 2>/dev/null || echo 0)
      /bin/launchctl kickstart system/${job}

      # Follow the job; if this process dies (e.g. T3 restarts), the job goes on.
      tail -c "+$((offset + 1))" -F ${log} 2>/dev/null &
      trap 'kill $! 2>/dev/null' EXIT
      until [ -f ${state}/result ] && read -r done_id status _ <${state}/result && [ "$done_id" = "$id" ]; do
        sleep 1
      done
      sleep 1
      exit "$status"
    '';
  };

  # fs_usage (file system, network, exec, disk I/O syscalls) for a single
  # process owned by the user. dtrace/dtruss can't trace syscalls with SIP on;
  # fs_usage uses kdebug and works. -R (replay a raw file) is not allowed.
  trace = pkgs.writeShellApplication {
    name = "trace-process";
    text = ''
      die() { echo "trace-process: $*" >&2; exit 2; }
      usage="usage: sudo trace-process [-f filesys|network|pathname|exec|diskio|cachehit] [-t seconds] <pid>"
      [ "$(id -u)" -eq 0 ] || die "run with sudo"
      flags=(-w)
      while [ $# -gt 1 ]; do
        case "$1:$2" in
          -f:filesys | -f:network | -f:pathname | -f:exec | -f:diskio | -f:cachehit) flags+=(-f "$2"); shift 2 ;;
          -t:*) [[ "$2" =~ ^[0-9]+$ ]] || die "$usage"; flags+=(-t "$2"); shift 2 ;;
          *) die "$usage" ;;
        esac
      done
      [ $# -eq 1 ] && [[ "$1" =~ ^[0-9]+$ ]] || die "$usage"
      owner=$(/bin/ps -o user= -p "$1" | tr -d ' ') || die "no process $1"
      [ "$owner" = ${lib.escapeShellArg user} ] || die "process $1 belongs to '$owner', not ${user}"
      exec /usr/bin/fs_usage "''${flags[@]}" "$1"
    '';
  };
in
{
  options.local.agentHost.deploy = {
    enable = lib.mkEnableOption "darwin-deploy, passwordless sudo for a few scoped commands, trace-process and Developer Mode";
    repository = lib.mkOption {
      type = lib.types.str;
      default = "${config.users.users.${user}.home}/config";
      description = "Local checkout darwin-deploy builds from; its origin is pushed to.";
    };
    configuration = lib.mkOption {
      type = lib.types.str;
      default = config.networking.localHostName;
    };
    variants = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-z0-9-]+");
      default = [ ];
      description = "Suffixes of test configurations darwin-deploy may switch to.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      deploy
      deployJob
      trace
    ];

    # The plist points at the stable /run/current-system path so it never
    # changes between generations: activation reloads changed daemons, which
    # would kill the deploy that is activating.
    launchd.daemons.darwin-deploy.serviceConfig = {
      Label = job;
      ProgramArguments = [ "/run/current-system/sw/bin/darwin-deploy-job" ];
      StandardOutPath = log;
      StandardErrorPath = log;
    };

    # Developer mode: the user may attach lldb/Instruments to their own
    # processes without an authorization prompt.
    system.activationScripts.postActivation.text = ''
      /usr/sbin/DevToolsSecurity -enable >/dev/null
      /usr/sbin/dseditgroup -o edit -a ${user} -t user _developer
    '';

    # Exact argument lists: `tailscale up` alone, so flags like --ssh,
    # --login-server or --advertise-routes still need a password. The
    # wrappers validate their own arguments. Each command is allowed by its
    # store path and by its root-owned /run/current-system link, since sudo
    # doesn't treat the two as the same command.
    security.sudo.extraConfig =
      lib.concatMapStrings
        (
          {
            name,
            path,
            args,
          }:
          lib.concatMapStrings (cmd: "${user} ALL=(root) NOPASSWD: ${cmd}${args}\n") [
            path
            "/run/current-system/sw/bin/${name}"
          ]
        )
        [
          {
            name = "darwin-deploy";
            path = lib.getExe deploy;
            args = "";
          }
          {
            name = "tailscale";
            path = lib.getExe tailscale;
            args = " up";
          }
          {
            name = "trace-process";
            path = lib.getExe trace;
            args = "";
          }
        ];
  };
}
