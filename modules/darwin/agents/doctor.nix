{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = config.system.primaryUser;
  home = config.users.users.${user}.home;
  t3 = config.local.agentHost.t3;
  cfg = config.local.agentHost.doctor;
  alwaysOn = config.local.agentHost.alwaysOn.enable;
  deploy = config.local.agentHost.deploy;
  lanHost = "${config.networking.localHostName}.local";
  tailscale = config.services.tailscale.package;

  opper = config.local.agentHost.opper;
  opperModels = lib.unique (lib.attrValues opper.claudeModels ++ lib.attrNames opper.opencodeModels);

  harnesses = {
    claude = "${home}/.local/bin/claude";
    codex = "${home}/.local/bin/codex";
    opencode = "${home}/.opencode/bin/opencode";
  };

  # Read-only health check of the running generation. Exits non-zero on FAIL;
  # warnings are things a human still has to do (logins, installs, pushes).
  doctor = pkgs.writeShellApplication {
    name = "t3-doctor";
    # http_code is unused when T3 is disabled.
    excludeShellChecks = [ "SC2329" ];
    runtimeInputs = [
      pkgs.curl
      pkgs.git
      pkgs.jq
      tailscale
    ];
    text = ''
      uid=$(id -u)
      [ "$uid" -ne 0 ] || { echo "t3-doctor: run as ${user}, not root" >&2; exit 2; }
      failed=0
      ok() { printf 'ok    %s\n' "$*"; }
      warn() { printf 'warn  %s\n' "$*"; }
      fail() { printf 'FAIL  %s\n' "$*"; failed=1; }
      http_code() { curl -s -o /dev/null -w '%{http_code}' -m "''${2:-5}" "$1" || true; }

      echo "t3-doctor $(/bin/date '+%Y-%m-%d %H:%M:%S') generation $(readlink /nix/var/nix/profiles/system)"

      # Every activation restarts the daemon, so a run overlapping a deploy retries.
      nix_ok() { for _ in 1 2 3 4 5; do nix store info >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
      if nix_ok; then ok "nix daemon reachable"; else fail "nix daemon reachable"; fi

      ${lib.optionalString alwaysOn ''
        pm=$(/usr/bin/pmset -g)
        if [ "$(awk '$1=="sleep"{print $2}' <<<"$pm")" = 0 ]; then ok "system sleep disabled"; else fail "system sleep disabled (pmset sleep is not 0)"; fi
        if [ "$(awk '$1=="autorestart"{print $2}' <<<"$pm")" = 1 ]; then ok "restart after power failure"; else fail "restart after power failure (pmset autorestart is not 1)"; fi

        state=''${XDG_STATE_HOME:-$HOME/.local/state}/t3-doctor
        mkdir -p "$state"
        now=$(/bin/date '+%Y-%m-%d %H:%M:%S')
        if [ -f "$state/last-check" ]; then
          since=$(cat "$state/last-check")
          sleeps=$(/usr/bin/pmset -g log | awk -v since="$since" '/Entering Sleep/ && ($1 " " $2) > since' | wc -l | tr -d ' ')
          if [ "$sleeps" = 0 ]; then ok "no system sleep since $since"; else fail "$sleeps system sleep(s) since $since (pmset -g log | grep 'Entering Sleep')"; fi
        else
          ok "sleep tracking starts now"
        fi
        echo "$now" >"$state/last-check"
      ''}

      ${
        if t3.enable then
          ''
            if /bin/launchctl print "gui/$uid/org.nixos.t3" 2>/dev/null | grep -q 'state = running'; then
              ok "T3 agent running"
            else
              fail "T3 agent running (launchctl print gui/$uid/org.nixos.t3; ~/Library/Logs/t3.log)"
            fi
            code=$(http_code http://127.0.0.1:${toString t3.port}/)
            if [ "$code" != 000 ]; then ok "T3 answers on 127.0.0.1:${toString t3.port} (HTTP $code)"; else fail "T3 answers on 127.0.0.1:${toString t3.port}"; fi
            # T3 sessions last a fixed 30 days and aren't renewed by use.
            if sessions=$(${t3.package}/bin/t3 auth session list --json 2>/dev/null); then
              expiring=$(jq -r '[.[] | select((.expiresAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - now < 7 * 86400)
                | "\(.client.label // .subject) (\(.expiresAt[0:10]))"] | join(", ")' <<<"$sessions")
              if [ -n "$expiring" ]; then
                warn "T3 sessions expiring within 7 days: $expiring (re-pair with t3-pair <label>)"
              else
                ok "$(jq length <<<"$sessions") paired T3 session(s), none expiring within 7 days"
              fi
            else
              warn "could not list T3 sessions"
            fi
          ''
        else
          ""
      }
      ${
        if t3.enable && t3.tailscale then
          ''
            status=$(tailscale status --json 2>/dev/null || echo '{}')
            backend=$(jq -r '.BackendState // "unreachable"' <<<"$status")
            case "$backend" in
              Running)
                ok "tailscale running"
                suffix=$(jq -r .MagicDNSSuffix <<<"$status")
                t3_url=https://${t3.serviceName}.$suffix
                code=$(http_code "$t3_url/" 30)
                if [ "$code" != 000 ]; then ok "T3 reachable at $t3_url (HTTP $code)"; else fail "T3 reachable at $t3_url (see /var/log/t3-tailscale-serve.log)"; fi
                # Any HTTP response (502 when no dev server runs) means the port is published.
                missing=()
                for port in ${lib.concatMapStringsSep " " toString t3.previewPorts}; do
                  [ "$(http_code "https://${t3.previewServiceName}.$suffix:$port/" 15)" != 000 ] || missing+=("$port")
                done
                if [ ''${#missing[@]} -eq 0 ]; then
                  ok "previews published at https://${t3.previewServiceName}.$suffix:{${
                    lib.concatMapStringsSep "," toString t3.previewPorts
                  }}"
                else
                  fail "previews not published at https://${t3.previewServiceName}.$suffix on: ''${missing[*]}"
                fi
                ;;
              NeedsLogin | NoState) warn "tailscale not logged in: sudo tailscale up" ;;
              *) fail "tailscale state: $backend" ;;
            esac
          ''
        else if t3.enable then
          ''
            code=$(http_code http://${lanHost}:${toString t3.port}/)
            if [ "$code" != 000 ]; then ok "T3 reachable on LAN at http://${lanHost}:${toString t3.port}"; else fail "T3 reachable on LAN at http://${lanHost}:${toString t3.port}"; fi
          ''
        else
          ""
      }
      ${lib.optionalString t3.enable (
        lib.concatStrings (
          lib.mapAttrsToList (name: path: ''
            if [ -x ${path} ]; then ok "${name} installed"; else warn "${name} not installed (${path})"; fi
          '') harnesses
        )
      )}
      ${lib.optionalString opper.enable ''
        # Every configured model must be an allowed EU route; any allowed
        # non-EU route means Opper's EU-only allowlist isn't active.
        if key=$(/usr/bin/security find-generic-password -a "$(id -un)" -s ${opper.keychainItem} -w 2>/dev/null); then
          if models=$(curl -fsS -m 30 -H "Authorization: Bearer $key" "https://api.opper.ai/v3/models?type=llm&include=policy&limit=1000"); then
            for model in ${lib.escapeShellArgs opperModels}; do
              jq -e --arg m "$model" 'any(.models[]; .id == $m and .region == "EU" and .policy.allowed)' <<<"$models" >/dev/null \
                || fail "Opper model $model is not an allowed EU route"
            done
            non_eu=$(jq '[.models[] | select(.region != "EU" and .policy.allowed)] | length' <<<"$models")
            if [ "$non_eu" = 0 ]; then
              ok "Opper allows EU routes only; configured models are EU"
            else
              warn "Opper allows $non_eu non-EU routes: EU-only allowlist not active (configured models are pinned to EU)"
            fi
          else
            warn "could not reach Opper to check model routes"
          fi
        else
          warn "no Opper key in keychain item ${opper.keychainItem}"
        fi
      ''}
      ${lib.optionalString deploy.enable ''
        # Deploys run as a launchd job and may outlive the session that started them.
        if [ -f /var/lib/darwin-deploy/request ] && read -r req_id req_action req_config _ </var/lib/darwin-deploy/request; then
          res_id=
          [ -f /var/lib/darwin-deploy/result ] && read -r res_id res_status res_time </var/lib/darwin-deploy/result
          if [ "$res_id" != "$req_id" ]; then
            if pgrep -f darwin-deploy-job >/dev/null; then
              warn "deploy in progress ($req_action $req_config); follow /var/log/darwin-deploy.log"
            else
              fail "last deploy ($req_action $req_config) never finished; see /var/log/darwin-deploy.log"
            fi
          elif [ "$res_status" = 0 ]; then
            ok "last deploy succeeded ($req_action $req_config at $res_time)"
          else
            fail "last deploy failed with status $res_status ($req_action $req_config at $res_time); see /var/log/darwin-deploy.log"
          fi
        fi

        rev=$(jq -r '.configurationRevision // empty' /run/current-system/darwin-version.json 2>/dev/null || true)
        if [ -z "$rev" ]; then
          warn "running generation has no recorded commit"
        elif [[ "$rev" == *-dirty ]]; then
          warn "running generation was built from uncommitted changes ($rev)"
        elif ! GIT_TERMINAL_PROMPT=0 git -C ${deploy.repository} -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 fetch --quiet origin 2>/dev/null; then
          warn "could not fetch origin to compare running commit ''${rev:0:12}"
        elif git -C ${deploy.repository} merge-base --is-ancestor "$rev" origin/main 2>/dev/null; then
          ok "running commit ''${rev:0:12} is on origin/main"
        else
          warn "running commit ''${rev:0:12} is not on origin/main (git -C ${deploy.repository} push origin $rev:main)"
        fi

      ''}
      exit "$failed"
    '';
  };

in
{
  options.local.agentHost.doctor.enable = lib.mkEnableOption "t3-doctor, run after login and daily";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ doctor ];

    # Runs after every login (so after each reboot) and every morning, which
    # catches overnight sleep. Results accumulate in ~/Library/Logs/t3-doctor.log.
    launchd.user.agents.t3-doctor.serviceConfig = {
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "sleep 120; exec ${lib.getExe doctor}"
      ];
      RunAtLoad = true;
      StartCalendarInterval = [
        {
          Hour = 9;
          Minute = 0;
        }
      ];
      StandardOutPath = "${home}/Library/Logs/t3-doctor.log";
      StandardErrorPath = "${home}/Library/Logs/t3-doctor.log";
    };
  };
}
