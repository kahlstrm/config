{
  writeShellApplication,
  coreutils,
  systemd,
}:
writeShellApplication {
  name = "steam-session-control";
  text = ''
    usage() {
      echo "Usage: steam-session {status|stop|restart|logs} {gamescope|steam|sunshine}" >&2
      echo "       steam-session {status|restart|logs} {wireplumber|pipewire|pipewire-pulse}" >&2
      exit 2
    }

    [ "$#" -eq 2 ] || usage
    case "$1" in
      status|stop|restart|logs) action="$1" ;;
      *) usage ;;
    esac
    case "$2" in
      gamescope) unit=gamescope-session.service ;;
      steam) unit=steam-launcher.service ;;
      sunshine) unit=sunshine.service ;;
      wireplumber|pipewire|pipewire-pulse)
        [ "$action" != stop ] || usage
        unit="$2.service"
        ;;
      *) usage ;;
    esac

    runtimeDir="/run/user/$(${coreutils}/bin/id -u)"
    sessionEnv=(
      ${coreutils}/bin/env -i
      "HOME=$HOME"
      "XDG_RUNTIME_DIR=$runtimeDir"
      "DBUS_SESSION_BUS_ADDRESS=unix:path=$runtimeDir/bus"
      SYSTEMD_PAGER=cat
      SYSTEMD_COLORS=0
    )
    if [ "$action" = logs ]; then
      exec "''${sessionEnv[@]}" ${systemd}/bin/journalctl \
        --user --no-pager --lines=100 --user-unit "$unit"
    fi
    exec "''${sessionEnv[@]}" ${systemd}/bin/systemctl \
      --user --no-pager "$action" "$unit"
  '';
}
