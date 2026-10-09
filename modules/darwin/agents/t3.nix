{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentHost.t3;
  user = config.system.primaryUser;
  home = config.users.users.${user}.home;
  tailscale = config.services.tailscale.package;
  # Behind Tailscale Serve, T3 only needs loopback; otherwise serve the LAN.
  host = if cfg.tailscale then "127.0.0.1" else "0.0.0.0";

  # Tailscale Services: T3 at https://<service>.<tailnet>.ts.net and each
  # preview port at https://<previewService>.<tailnet>.ts.net:<port>. Service
  # config has no node name in it, so renames don't affect it. Rebuilt from
  # scratch on every load so removed ports disappear.
  serve = pkgs.writeShellScript "t3-tailscale-serve" ''
    set -eu
    ts=${lib.getExe tailscale}
    until [ "$($ts status --json 2>/dev/null | ${lib.getExe pkgs.jq} -r .BackendState)" = Running ]; do
      sleep 10
    done
    $ts serve reset
    $ts serve clear svc:${cfg.serviceName} || true
    $ts serve clear svc:${cfg.previewServiceName} || true
    $ts serve --service=svc:${cfg.serviceName} --https=443 http://127.0.0.1:${toString cfg.port}
    ${lib.concatMapStrings (port: ''
      $ts serve --service=svc:${cfg.previewServiceName} --https=${toString port} http://127.0.0.1:${toString port}
    '') cfg.previewPorts}
    echo "$(date '+%F %T') published svc:${cfg.serviceName} and svc:${cfg.previewServiceName}"
  '';

  # Exports each configured login keychain secret as an environment variable
  # for T3 and the harnesses it spawns. A missing item is logged, not fatal,
  # so T3 stays reachable while the secret is being added.
  launcher = pkgs.writeShellScript "t3-launch" ''
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (var: item: ''
        if value=$(/usr/bin/security find-generic-password -a "$(/usr/bin/id -un)" -s ${lib.escapeShellArg item} -w 2>/dev/null); then
          export ${var}="$value"
        else
          echo "t3-launch: keychain item ${item} not found, ${var} unset" >&2
        fi
      '') cfg.keychainEnvironment
    )}
    exec ${cfg.package}/bin/t3 "$@"
  '';

  declaredSettings = (pkgs.formats.json { }).generate "t3-settings.json" cfg.settings;

  # One-time pairing link for a device, as a QR code for phones.
  pair = pkgs.writeShellApplication {
    name = "t3-pair";
    runtimeInputs = [
      cfg.package
      tailscale
      pkgs.jq
      pkgs.qrencode
    ];
    text = ''
      label=''${1:?usage: t3-pair <device label> [ttl, default 5m]}
      ttl=''${2:-5m}
      url=https://${cfg.serviceName}.$(tailscale status --json | jq -r .MagicDNSSuffix)
      pairing=$(t3 auth pairing create --base-url "$url" --ttl "$ttl" --label "$label" --json)
      link=$(jq -r .pairUrl <<<"$pairing")
      qrencode -t ansiutf8 "$link"
      echo "$link"
      echo "Code: $(jq -r .credential <<<"$pairing")  (to type in at $url instead)"
      echo "One-time pairing for '$label', valid for $ttl. Use it on the device with Tailscale connected."
    '';
  };
in
{
  options.local.agentHost.t3 = {
    enable = lib.mkEnableOption "T3 Code server as a login agent";
    package = lib.mkOption {
      type = lib.types.package;
      # T3 installs and updates the harnesses itself; don't bundle Codex.
      default = pkgs.t3code.override { enableCodex = false; };
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 3773;
    };
    settings = lib.mkOption {
      type = (pkgs.formats.json { }).type;
      default = { };
      description = ''
        Declared T3 server settings, deep-merged into ~/.t3/userdata/settings.json
        on every switch (objects merge, other values are replaced). Keys not
        declared keep what was set in the UI. T3 reloads the file when it changes.
      '';
    };
    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for T3 and the harnesses it starts.";
    };
    keychainEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        OPPER_API_KEY = "opper-api-key";
      };
      description = ''
        Environment variables for T3 and its harnesses, each read from the
        login keychain item (generic password) with the given service name.
      '';
    };
    tailscale = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run Tailscale and publish T3 and previews as Tailscale Services over HTTPS.";
    };
    serviceName = lib.mkOption {
      type = lib.types.strMatching "[a-z][a-z0-9-]*";
      default = "t3";
    };
    previewServiceName = lib.mkOption {
      type = lib.types.strMatching "[a-z][a-z0-9-]*";
      default = "preview";
    };
    previewPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = ''
        Local dev server ports published on the tailnet as
        https://<host>.<tailnet>.ts.net:<port>, for previewing what agents build.
        Dev servers can keep listening on localhost only.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        environment.systemPackages = [ cfg.package ];

        home-manager.users.${user} =
          { lib, ... }:
          {
            home.activation.t3Settings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
              settings=${home}/.t3/userdata/settings.json
              run mkdir -p "$(dirname "$settings")"
              [ -f "$settings" ] || echo '{}' >"$settings"
              if merged=$(${lib.getExe pkgs.jq} -s '.[0] * .[1]' "$settings" ${declaredSettings}); then
                # Atomic replace in the same directory; T3 watches the file.
                tmp=$(mktemp "$settings.XXXXXX")
                echo "$merged" >"$tmp" && run mv "$tmp" "$settings"
              else
                echo "t3: $settings is not valid JSON; declared settings not applied" >&2
              fi
            '';
          };

        # Runs in the user's login session, so it starts once the user logs
        # in (after FileVault unlock) and can use the login keychain.
        launchd.user.agents.t3.serviceConfig = {
          ProgramArguments = [
            "${launcher}"
            "serve"
            "--host"
            host
            "--port"
            (toString cfg.port)
            "--no-browser"
            home
          ];
          WorkingDirectory = home;
          # Harness CLIs are installed and updated by T3 itself (setup screen,
          # Settings > Providers) or their own installers, into the home dir.
          EnvironmentVariables = cfg.environment // {
            PATH = lib.concatStringsSep ":" [
              "${home}/.local/bin"
              "${home}/.opencode/bin"
              "/etc/profiles/per-user/${user}/bin"
              "/run/current-system/sw/bin"
              "/nix/var/nix/profiles/default/bin"
              "/usr/bin"
              "/bin"
              "/usr/sbin"
              "/sbin"
            ];
          };
          RunAtLoad = true;
          KeepAlive = true;
          ProcessType = "Interactive";
          StandardOutPath = "${home}/Library/Logs/t3.log";
          StandardErrorPath = "${home}/Library/Logs/t3.log";
        };
      }
      (lib.mkIf cfg.tailscale {
        services.tailscale.enable = true;
        environment.systemPackages = [ pair ];

        # Runs on every load (boot, or a deploy that changes it) and retries
        # until it succeeds; serve config persists in tailscaled's state.
        launchd.daemons.t3-tailscale-serve.serviceConfig = {
          ProgramArguments = [ "${serve}" ];
          RunAtLoad = true;
          KeepAlive.SuccessfulExit = false;
          ThrottleInterval = 30;
          StandardOutPath = "/var/log/t3-tailscale-serve.log";
          StandardErrorPath = "/var/log/t3-tailscale-serve.log";
        };
      })
    ]
  );
}
