{ pkgs }:
let
  steamMachine =
    moduleArgs:
    (import ../modules/steam-machine.nix moduleArgs) {
      inherit pkgs;
      lib = pkgs.lib;
      currentSystemUser = "operator";
      isStable = false;
      config.users.users.steam-machine.home = "/home/steam-machine";
    };
  adminRules = (steamMachine { adminUsers = [ "operator" ]; }).security.sudo.extraRules;
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
assert (steamMachine { }).security.sudo.extraRules == [ ];
assert builtins.length adminRules == 1;
assert (builtins.head adminRules).users == [ "operator" ];
assert (builtins.head adminRules).runAs == "steam-machine";
assert
  (builtins.head adminRules).commands == [
    {
      command = "${pkgs.callPackage ../modules/steam-session/package.nix { }}/bin/steam-session-control";
      options = [
        "NOPASSWD"
        "NOSETENV"
      ];
    }
  ];
pkgs.runCommand "steam-session-tests"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.binutils
    ];
  }
  ''
    control=${control}/bin/steam-session-control
    for binary in steam-session steam-session-control; do
      readelf -l ${control}/bin/$binary > headers
      if grep -q 'INTERP' headers; then
        echo "Unexpected dynamic loader in $binary" >&2
        exit 1
      fi
    done
    cat > startup.sh <<'EOF'
    echo injected > "$PWD/shell-startup"
    EOF
    for arguments in "" "restart" "restart unknown" "status --help" "shell steam" \
      "stop steam extra" "logs /etc/passwd" "stop wireplumber" \
      "stop pipewire" "stop pipewire-pulse"; do
      if $control $arguments > rejected 2>&1; then
        echo "Unexpectedly accepted: $arguments" >&2
        exit 1
      fi
      grep -q '^Usage:' rejected
    done

    for service in 'steam; touch escaped' '$(touch escaped)' 'steam*' '--all' \
      'steam.service' 'steam sunshine'; do
      if $control status "$service" > rejected 2>&1; then
        echo "Unexpectedly accepted service: $service" >&2
        exit 1
      fi
      grep -q '^Usage:' rejected
    done
    test ! -e escaped

    for action in status stop restart logs; do
      for service in gamescope steam sunshine wireplumber pipewire pipewire-pulse; do
        case "$action:$service" in
          stop:wireplumber|stop:pipewire|stop:pipewire-pulse) continue ;;
        esac
        HOME=/tmp/caller-home BASH_ENV="$PWD/startup.sh" \
          INJECTED=unsafe SYSTEMD_PAGER=/bin/sh $control "$action" "$service" > result
        test ! -e shell-startup
        grep -qx -- '--no-pager' result
        grep -qx 'SYSTEMD_PAGER=cat' result
        grep -qx 'HOME=/home/steam-machine' result
        grep -qx "XDG_RUNTIME_DIR=/run/user/$(id -u)" result
        grep -qx "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus" result
        if grep -q '^INJECTED=' result; then exit 1; fi
        case "$service" in
          gamescope) unit=gamescope-session.service ;;
          steam) unit=steam-launcher.service ;;
          sunshine) unit=sunshine.service ;;
          wireplumber|pipewire|pipewire-pulse) unit="$service.service" ;;
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
