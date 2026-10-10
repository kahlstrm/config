{ pkgs }:
let
  fakeSystemd = pkgs.runCommand "steam-session-systemd" { } ''
    mkdir -p "$out/bin"
    for command in systemctl journalctl; do
      cat > "$out/bin/$command" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$@"
    ${pkgs.coreutils}/bin/env
    EOF
      chmod +x "$out/bin/$command"
    done
  '';
  control = pkgs.callPackage ../modules/steam-session/package.nix { systemd = fakeSystemd; };
in
pkgs.runCommand "steam-session-tests" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  control=${control}/bin/steam-session-control
  for arguments in "" "restart" "restart unknown" "status --help" "shell steam" \
    "stop steam extra" "logs /etc/passwd"; do
    if $control $arguments > rejected 2>&1; then
      echo "Unexpectedly accepted: $arguments" >&2
      exit 1
    fi
    grep -q '^Usage:' rejected
  done

  for action in status stop restart logs; do
    for service in gamescope steam sunshine; do
      INJECTED=unsafe SYSTEMD_PAGER=/bin/sh $control "$action" "$service" > result
      grep -qx -- '--no-pager' result
      grep -qx 'SYSTEMD_PAGER=cat' result
      grep -qx "XDG_RUNTIME_DIR=/run/user/$(id -u)" result
      grep -qx "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus" result
      if grep -q '^INJECTED=' result; then exit 1; fi
      case "$service" in
        gamescope) unit=gamescope-session.service ;;
        steam) unit=steam-launcher.service ;;
        sunshine) unit=sunshine.service ;;
      esac
      grep -qx "$unit" result
      if [ "$action" = logs ]; then
        grep -qx -- '--user-unit' result
        grep -qx -- '--lines=100' result
      else
        grep -qx "$action" result
      fi
    done
  done
  touch "$out"
''
