# host-deploy: queue a deployment of this machine's own configuration from merged upstream
# main, or report on it. Ops runs it as its forced SSH command (modules/ops-deploy.nix) and
# an Amp runner runs it locally (modules/amp-runner.nix); polkit decides who may queue it.
#   deploy  queue agent-deploy for the machine's own configuration
#   status  the unit's state and the runner's last status.json
#   log     the unit's recent journal, copied by agent-deploy-log.service
#   restart-vm <name>  restart microvm@<name> for a VM in `restartableVMs`, booting the
#           image a deploy staged; it returns at once
{
  lib,
  writeShellApplication,
  systemd,
  coreutils,
  configuration,
  restartableVMs ? [ ],
}:
let
  state = "/nix/var/nix/profiles/agent-deploy";
in
writeShellApplication {
  name = "host-deploy";
  runtimeInputs = [
    systemd
    coreutils
  ];
  text = ''
    request="''${SSH_ORIGINAL_COMMAND-$*}"
    case "$request" in
    deploy)
      systemctl --no-ask-password start --no-block agent-deploy.service
      echo "Deployment of merged main to ${configuration} queued; follow it with status and log."
      ;;
    status)
      systemctl show agent-deploy.service --property ActiveState,Result,ExecMainStartTimestamp,ExecMainExitTimestamp
      cat ${state}/status.json 2>/dev/null || echo 'No deployment has run yet.'
      ;;
    log)
      systemctl --no-ask-password start agent-deploy-log.service
      cat /run/agent-deploy-log/log
      ;;
    ${lib.concatMapStrings (vm: ''
      "restart-vm ${vm}")
        systemctl --no-ask-password restart --no-block microvm@${vm}.service
        echo "Restarting the ${vm} VM to boot its staged image."
        ;;
    '') restartableVMs}
    *)
      echo 'Usage: host-deploy deploy | status | log${
        lib.optionalString (
          restartableVMs != [ ]
        ) " | restart-vm <${lib.concatStringsSep "|" restartableVMs}>"
      }' >&2
      exit 2
      ;;
    esac
  '';
}
