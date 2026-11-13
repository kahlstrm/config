# Off-host backups with restic. docs/backups.md describes the whole setup, its checks and how
# to restore.
#
# `backup.service` backs up `paths` nightly to two repositories that share one password:
# zima's, on its system disk away from the media array, for fast restores, then the Storage
# Box's, off-site. Each host writes to both itself, so losing zima stops no other host's
# off-site backups, and a failure in one repository does not skip the other. SQLite
# databases under `paths` are copied with SQLite's online backup first; the copies under
# /var/lib/backup/sqlite replace the live files in the snapshot, which could be torn.
#
# The repository password, the SSH key both repositories trust and the off-site
# repository's location are not in this repository. Hosts get them from the private secrets
# repository (`credentials`, set by modules/backup-credentials.nix); credentials in the
# systemd credstore are read too, which the VM test uses. Every unit here reads them from its
# credentials directory, and backs up off-site once `backup-offsite` is there.
#
# A host that cannot reach zima (`toZima = false`) backs up off-site only, and zima copies
# its snapshots down (`server.mirrorHosts`). zima (`server.enable`) serves its repository
# over SFTP to the backup key alone, creates both repositories, checks them, and is the only
# host that deletes snapshots. Its checks write node-exporter metrics that the cluster's
# Prometheus alerts on. `drop.enable` gives the cluster's backup jobs a write-only SFTP drop
# whose files this host backs up.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.backup;
  keys = import ../lib/ssh-keys.nix;
  zimaRepository = "sftp:restic@zima.kalski.xyz:/repo";
  localRepository = "/var/lib/restic/repo";
  authorizedKeys = "/var/lib/restic/authorized_keys";
  dropDirectory = "/var/lib/backup-drop/incoming";
  stage = "/var/lib/backup/sqlite";
  metrics = "/var/lib/prometheus-node-exporter-text";
  paths = cfg.paths ++ lib.optional cfg.drop.enable dropDirectory;
  # Credentials from files take precedence over the ones installed in the credstore.
  loadCredential = lib.mapAttrsToList (name: file: "backup-${name}:${file}") (
    lib.filterAttrs (_: file: file != null) {
      password = cfg.credentials.passwordFile;
      ssh-key = cfg.credentials.sshKeyFile;
      offsite = cfg.credentials.offsiteRepositoryFile;
    }
  );
  credentialProperties = [
    "ImportCredential=backup-*"
  ]
  ++ map (credential: "LoadCredential=${credential}") loadCredential;
  # zima's host key is pinned through programs.ssh.knownHosts. The Storage Box's is kept on
  # first use: restic authenticates everything it reads with the repository key, so a wrong
  # server can only withhold backups, which the checks report.
  sshConfig = pkgs.writeText "backup-ssh-config" ''
    Host *
      IdentitiesOnly yes
      BatchMode yes
      UserKnownHostsFile /var/lib/backup/known_hosts
      StrictHostKeyChecking accept-new
      ServerAliveInterval 60
      ServerAliveCountMax 10
  '';
  # restic with the imported credentials. Run by hand, outside these units, it runs itself in
  # a transient unit that imports them.
  restic = pkgs.writeShellScriptBin "restic-backup" ''
    if [ -z "''${CREDENTIALS_DIRECTORY:-}" ]; then
      exec ${config.systemd.package}/bin/systemd-run --quiet --pipe --wait --collect --same-dir \
        ${
          lib.concatMapStringsSep " " (property: "-p ${lib.escapeShellArg property}") credentialProperties
        } \
        -p StateDirectory=backup -p CacheDirectory=backup "$(readlink -f "$0")" "$@"
    fi
    if [ ! -s "$CREDENTIALS_DIRECTORY/backup-password" ] || [ ! -s "$CREDENTIALS_DIRECTORY/backup-ssh-key" ]; then
      echo "The backup credentials are not installed; see docs/backups.md." >&2
      exit 1
    fi
    export PATH=${config.programs.ssh.package}/bin:$PATH
    export RESTIC_PASSWORD_FILE=$CREDENTIALS_DIRECTORY/backup-password RESTIC_CACHE_DIR=/var/cache/backup
    exec ${lib.getExe pkgs.restic} -o sftp.args="-F ${sshConfig} -i $CREDENTIALS_DIRECTORY/backup-ssh-key" \
      --retry-lock 1h "$@"
  '';
  # Shared by the scripts: the repositories this host reaches, as restic arguments.
  repositories = ''
    declare -A repository=()
    ${lib.optionalString (cfg.toZima || cfg.server.enable) ''
      repository[zima]="-r ${zimaRepository}"
    ''}
    if [ -s "''${CREDENTIALS_DIRECTORY:-/nonexistent}/backup-offsite" ]; then
      repository[offsite]="--repository-file $CREDENTIALS_DIRECTORY/backup-offsite"
    fi
  '';
  # Seconds since the epoch of a restic JSON time, such as 2026-11-11T02:00:01.5+02:00.
  jqEpoch = ''
    def epoch: sub("\\.[0-9]+"; "") |
      if endswith("Z") then fromdateiso8601
      else (.[0:19] + "Z" | fromdateiso8601)
        - (if .[19:20] == "-" then -1 else 1 end) * ((.[20:22] | tonumber) * 3600 + (.[23:25] | tonumber) * 60)
      end;
  '';
  # Writes stdin to a node-exporter textfile atomically.
  writeMetrics = ''
    write_metrics() {
      local file=${metrics}/$1.prom
      cat >"$file.tmp"
      chmod 0644 "$file.tmp"
      mv "$file.tmp" "$file"
    }
  '';
  script =
    name: runtimeInputs: text:
    lib.getExe (
      pkgs.writeShellApplication {
        inherit name text;
        runtimeInputs = [
          restic
          pkgs.coreutils
        ]
        ++ runtimeInputs;
      }
    );
  backupScript = script "backup" [ pkgs.findutils pkgs.sqlite ] ''
    for path in ${lib.escapeShellArgs paths}; do
      if [ -L "$path" ]; then
        echo "$path is a symlink, which restic backs up as the link alone; back up its target." >&2
        exit 1
      fi
    done
    # Copy each SQLite database under the paths, and list the live files for restic to skip.
    rm -rf ${stage}
    install -d -m 0700 ${stage}
    : >/run/backup/sqlite-excludes
    find ${lib.escapeShellArgs paths} -type f \
      \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0 |
      while IFS= read -r -d "" db; do
        if [ "$(head -c 15 "$db")" != "SQLite format 3" ]; then
          continue
        fi
        case "$db" in *"'"* | *$'\n'*)
          echo "Cannot copy $db: its name holds a quote or a newline." >&2
          exit 1
          ;;
        esac
        install -d -m 0700 "${stage}$(dirname "$db")"
        sqlite3 -cmd '.timeout 60000' "$db" ".backup '${stage}$db'"
        printf '%s\n' "$db" "$db-wal" "$db-shm" "$db-journal" >>/run/backup/sqlite-excludes
      done

    ${repositories}
    if [ ''${#repository[@]} -eq 0 ]; then
      echo "No repository to back up to: install backup-offsite (docs/backups.md)." >&2
      exit 1
    fi
    status=0
    for name in zima offsite; do
      [ -n "''${repository[$name]:-}" ] || continue
      read -ra args <<<"''${repository[$name]}"
      ${lib.optionalString cfg.server.enable ''
        # zima creates the off-site repository with its own repository's chunker parameters, so
        # that `restic copy` between the two deduplicates. 10: no repository there yet.
        if [ "$name" = offsite ]; then
          exists=0
          restic-backup "''${args[@]}" cat config --no-lock >/dev/null || exists=$?
          if [ "$exists" -eq 10 ]; then
            restic-backup "''${args[@]}" init --copy-chunker-params --from-repo ${zimaRepository} \
              --from-password-file "$CREDENTIALS_DIRECTORY/backup-password" || status=1
          fi
        fi
      ''}
      restic-backup "''${args[@]}" backup --exclude-file=${excludeFile} \
        --exclude-file=/run/backup/sqlite-excludes ${lib.escapeShellArgs paths} ${stage} || {
        echo "Backing up to $name failed." >&2
        status=1
      }
    done
    exit "$status"
  '';
  excludeFile = pkgs.writeText "backup-excludes" (lib.concatLines cfg.exclude);
  # Sources expected in a repository: the mirrored hosts arrive only through the off-site one.
  expectedSources = ''
    sources=(${lib.escapeShellArgs (lib.subtractLists cfg.server.mirrorHosts cfg.server.sources)})
    if [ -n "''${repository[offsite]:-}" ]; then
      sources+=(${lib.escapeShellArgs (lib.intersectLists cfg.server.mirrorHosts cfg.server.sources)})
    fi
  '';
  serverScripts = {
    # Derives the restic user's authorized key from the installed private key, and creates
    # the local repository.
    setup = script "backup-server" [ pkgs.openssh ] ''
      credentials=''${CREDENTIALS_DIRECTORY:-/nonexistent}
      if [ ! -s "$credentials/backup-password" ] || [ ! -s "$credentials/backup-ssh-key" ]; then
        echo "The backup credentials are not installed yet; see docs/backups.md."
        exit 0
      fi
      # sshd reads it as the restic user, so it sits in the chroot's root-owned top directory.
      printf 'restrict %s\n' "$(ssh-keygen -y -f "$credentials/backup-ssh-key")" >${authorizedKeys}.tmp
      chmod 0644 ${authorizedKeys}.tmp
      mv ${authorizedKeys}.tmp ${authorizedKeys}
      if [ ! -e ${localRepository}/config ]; then
        RESTIC_PASSWORD_FILE=$credentials/backup-password ${lib.getExe pkgs.restic} -r ${localRepository} init
        chown -R restic:restic ${localRepository}
      fi
    '';
    mirror = script "backup-mirror" [ ] ''
      ${repositories}
      if [ -z "''${repository[offsite]:-}" ]; then
        echo "No off-site repository is installed; nothing to mirror."
        exit 0
      fi
      status=0
      hosts=(${lib.escapeShellArgs cfg.server.mirrorHosts})
      for host in "''${hosts[@]}"; do
        restic-backup -r ${zimaRepository} copy --from-repository-file "$CREDENTIALS_DIRECTORY/backup-offsite" \
          --from-password-file "$CREDENTIALS_DIRECTORY/backup-password" --host "$host" latest || status=1
      done
      exit "$status"
    '';
    # Lists each repository: the newest snapshot of each source and the backed-up time of
    # each file the cluster drops. A failure to list shows as backup_repository_up 0.
    check = script "backup-check" [ pkgs.jq ] ''
      ${repositories}
      ${expectedSources}
      ${writeMetrics}
      drop_hosts=(${lib.escapeShellArgs cfg.server.dropHosts})
      drop_files=(${lib.escapeShellArgs cfg.server.dropFiles})
      {
        for name in "''${!repository[@]}"; do
          read -ra args <<<"''${repository[$name]}"
          # restic prints a key's creation in local time, which is UTC in this unit.
          if snapshots=$(restic-backup "''${args[@]}" snapshots --no-lock --json) &&
            created=$(restic-backup "''${args[@]}" key list --no-lock --json |
              jq '[.[].created | sub(" "; "T") + "Z" | fromdateiso8601] | min'); then
            echo "backup_repository_up{repository=\"$name\"} 1"
            echo "backup_repository_created_timestamp_seconds{repository=\"$name\"} $created"
            for source in "''${sources[@]}"; do
              time=$(jq --arg source "$source" '${jqEpoch} [.[] | select(.hostname == $source) | .time | epoch] | max // 0' <<<"$snapshots")
              echo "backup_snapshot_newest_timestamp_seconds{repository=\"$name\",source=\"$source\"} $time"
            done
            for host in "''${drop_hosts[@]}"; do
              nodes=$(restic-backup "''${args[@]}" ls --no-lock --json latest --host "$host" ${dropDirectory}) || nodes=""
              for file in "''${drop_files[@]}"; do
                time=$(jq -s --arg file "$file" '${jqEpoch} [.[] | select(.struct_type == "node" and .name == $file) | .mtime | epoch] | max // 0' <<<"$nodes")
                echo "backup_file_mtime_seconds{repository=\"$name\",source=\"$host\",file=\"$file\"} $time"
              done
            done
          else
            echo "backup_repository_up{repository=\"$name\"} 0"
          fi
        done
        echo "backup_check_last_run_timestamp_seconds $(date +%s)"
      } | write_metrics backup
    '';
    # Checks a seventh of each repository's data, a different seventh each day, then
    # restores each source's latest snapshot and verifies it.
    restoreCheck = script "backup-restore-check" [ pkgs.findutils pkgs.jq pkgs.sqlite pkgs.unzip ] ''
      ${repositories}
      ${expectedSources}
      ${writeMetrics}
      drop_hosts=(${lib.escapeShellArgs cfg.server.dropHosts})
      # Prints each problem in a restored source; fails if there is one.
      verify() {
        local source=$1 root=$2 status=0 db result
        if [ ! -s "$root/etc/ssh/ssh_host_ed25519_key" ]; then
          echo "$source: no SSH host key" >&2
          status=1
        fi
        while IFS= read -r -d "" db; do
          result=$(sqlite3 "file:$db?immutable=1" 'PRAGMA integrity_check' 2>&1) || true
          if [ "$result" != ok ]; then
            echo "$source: ''${db#"$root${stage}"}: $result" >&2
            status=1
          fi
        done < <(find "$root${stage}" -type f -print0 2>/dev/null)
        if [[ " ''${drop_hosts[*]} " == *" $source "* ]]; then
          local drop=$root${dropDirectory}
          # Pocket ID's export, without its encryption key, which stays in Git.
          if ! unzip -p "$drop/pocket-id-export.zip" database.json |
            jq -e '(.tables.users | length) > 0 and (.tables.kv | length) > 0' >/dev/null; then
            echo "$source: Pocket ID's export is missing or has no users or keys" >&2
            status=1
          fi
          # The Terraform state, encrypted to the offline recovery key; only its form is checked.
          if ! jq -e '(.sops.age | length) > 0 and (.data | startswith("ENC["))' "$drop/terraform-state.tar.sops" >/dev/null; then
            echo "$source: the Terraform state export is missing or not encrypted" >&2
            status=1
          fi
        fi
        return "$status"
      }
      part=$(($(date +%s) / 86400 % 7 + 1))
      {
        for name in "''${!repository[@]}"; do
          read -ra args <<<"''${repository[$name]}"
          ok=1
          restic-backup "''${args[@]}" check --read-data-subset "$part/7" >&2 || ok=0
          for source in "''${sources[@]}"; do
            target=$(mktemp -d /var/tmp/backup-restore.XXXXXX)
            if restic-backup "''${args[@]}" restore latest --host "$source" --target "$target" \
              --include /etc/ssh/ssh_host_ed25519_key --include ${stage} --include ${dropDirectory} >&2; then
              verify "$source" "$target" || ok=0
            else
              echo "$name: restoring $source failed" >&2
              ok=0
            fi
            rm -rf "$target"
          done
          echo "backup_restore_check_success{repository=\"$name\"} $ok"
          # The first pass is kept for good. It ends the mute on the backup alerts while the
          # backups were new (infra/local-kubernetes/platform/observability).
          if [ "$ok" = 1 ] && [ ! -e "${metrics}/backup-first-restore-$name.prom" ]; then
            echo "backup_restore_check_first_success_timestamp_seconds{repository=\"$name\"} $(date +%s)" |
              write_metrics "backup-first-restore-$name"
          fi
        done
        echo "backup_restore_check_last_run_timestamp_seconds $(date +%s)"
      } | write_metrics backup-restore
    '';
    prune = script "backup-prune" [ ] ''
      ${repositories}
      ${writeMetrics}
      for name in "''${!repository[@]}"; do
        read -ra args <<<"''${repository[$name]}"
        restic-backup "''${args[@]}" forget --prune --group-by host \
          --keep-daily 7 --keep-weekly 5 --keep-monthly 12
      done
      echo "backup_prune_last_success_timestamp_seconds $(date +%s)" | write_metrics backup-prune
    '';
  };
  serviceConfig = {
    Type = "oneshot";
    ImportCredential = "backup-*";
    LoadCredential = loadCredential;
    StateDirectory = "backup";
    StateDirectoryMode = "0700";
    CacheDirectory = "backup";
    CacheDirectoryMode = "0700";
    Nice = 10;
    IOSchedulingClass = "idle";
  };
  job = name: description: execStart: calendar: {
    services.${name} = {
      inherit description;
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
      ]
      ++ lib.optional cfg.server.enable "backup-server.service";
      restartIfChanged = false;
      environment.TZ = "UTC";
      serviceConfig = serviceConfig // {
        ExecStart = execStart;
        RuntimeDirectory = name;
      };
    };
    timers.${name} = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = calendar;
        RandomizedDelaySec = "10m";
        Persistent = true;
      };
    };
  };
in
{
  options.local.backup = {
    enable = lib.mkEnableOption "nightly restic backups to zima and the Storage Box";
    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "State that Git cannot rebuild. Not symlinks: restic backs up a link, not its target.";
    };
    exclude = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "restic exclude patterns, for caches and logs under `paths`.";
    };
    toZima = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether this host reaches zima's repository. Otherwise zima copies its snapshots from off-site.";
    };
    credentials = lib.genAttrs [ "passwordFile" "sshKeyFile" "offsiteRepositoryFile" ] (
      name:
      lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = lib.literalExpression "config.sops.secrets.backup-password.path";
        description = "File holding this credential, such as one sops-nix decrypts, instead of the one installed in the credstore.";
      }
    );
    drop.enable = lib.mkEnableOption "a write-only SFTP drop for the cluster's backup jobs, backed up with this host";
    server = {
      enable = lib.mkEnableOption "the local repository on this host, its checks and pruning";
      sources = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Hosts whose snapshots the checks expect in each repository.";
      };
      mirrorHosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Hosts whose latest off-site snapshot is copied into the local repository daily.";
      };
      dropHosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Hosts with a drop, whose dropped files the checks expect.";
      };
      dropFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "pocket-id-export.zip"
          "terraform-state.tar.sops"
        ];
        description = "Files the cluster's jobs drop on each drop host.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        programs.ssh.knownHosts."zima.kalski.xyz".publicKey = keys.hosts."zima.kalski.xyz";
        # Restores and manual runs, such as `restic-backup -r sftp:restic@zima.kalski.xyz:/repo snapshots`.
        environment.systemPackages = [ restic ];
        systemd = lib.mkMerge [
          (job "backup" "Back up state to zima and the Storage Box" backupScript "*-*-* 02:00 UTC")
          { timers.backup.timerConfig.RandomizedDelaySec = lib.mkForce "30m"; }
        ];
      }
      (lib.mkIf cfg.drop.enable {
        users.users.backup-drop = {
          isSystemUser = true;
          group = "backup-drop";
          home = "/var/lib/backup-drop";
          openssh.authorizedKeys.keys = [ "restrict ${keys.backupDrop}" ];
        };
        users.groups.backup-drop = { };
        systemd.tmpfiles.settings.backup-drop = {
          "/var/lib/backup-drop".d = {
            user = "root";
            group = "root";
            mode = "0755";
          };
          ${dropDirectory}.d = {
            user = "backup-drop";
            group = "backup-drop";
            mode = "0700";
          };
        };
        # Uploads and renames only: the drop can't read, list or delete what it wrote.
        services.openssh.extraConfig = ''
          Match User backup-drop
            AuthenticationMethods publickey
            ChrootDirectory /var/lib/backup-drop
            ForceCommand internal-sftp -d /incoming -u 077 -P read,readdir,opendir,remove,rmdir,readlink,symlink,hardlink,copy-data
            AllowAgentForwarding no
            AllowTcpForwarding no
            PermitTTY no
            X11Forwarding no
        '';
      })
      (lib.mkIf cfg.server.enable {
        users.users.restic = {
          isSystemUser = true;
          group = "restic";
          home = "/var/lib/restic";
        };
        users.groups.restic = { };
        # sshd's chroot must be root's; the repository inside it is restic's alone.
        systemd.tmpfiles.settings.backup-repository = {
          "/var/lib/restic".d = {
            user = "root";
            group = "root";
            mode = "0755";
          };
          ${localRepository}.d = {
            user = "restic";
            group = "restic";
            mode = "0700";
          };
          ${metrics}.d = {
            user = "root";
            group = "root";
            mode = "0755";
          };
        };
        services.openssh.extraConfig = ''
          Match User restic
            AuthenticationMethods publickey
            AuthorizedKeysFile ${authorizedKeys}
            ChrootDirectory /var/lib/restic
            ForceCommand internal-sftp -d /repo
            AllowAgentForwarding no
            AllowTcpForwarding no
            PermitTTY no
            X11Forwarding no
        '';
        # A deploy that adds the credentials changes this unit, so the switch reruns it.
        systemd.services.backup-server = {
          description = "Authorize the backup key and create the local repository";
          wantedBy = [ "multi-user.target" ];
          after = [ "systemd-tmpfiles-setup.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ImportCredential = "backup-*";
            LoadCredential = loadCredential;
            StateDirectory = "backup";
            StateDirectoryMode = "0700";
            ExecStart = serverScripts.setup;
          };
        };
        # The cluster's Prometheus scrapes the checks' metrics.
        services.prometheus.exporters.node = {
          enable = true;
          extraFlags = [ "--collector.textfile.directory=${metrics}" ];
        };
      })
      (lib.mkIf cfg.server.enable {
        systemd = lib.mkMerge [
          (job "backup-mirror" "Copy off-site-only hosts' snapshots to the local repository"
            serverScripts.mirror
            "*-*-* 05:00 UTC"
          )
          (job "backup-check" "Check the backups' freshness" serverScripts.check "*-*-* 00/2:15 UTC")
          (job "backup-restore-check" "Restore and verify the latest backups" serverScripts.restoreCheck
            "*-*-* 08:00 UTC"
          )
          (job "backup-prune" "Delete old backups" serverScripts.prune "Sun *-*-* 06:00 UTC")
        ];
      })
    ]
  );
}
