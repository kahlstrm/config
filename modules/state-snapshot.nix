# Read-only btrfs snapshots of a service's state, for a one-way migration such as a database
# upgrade. `state-snapshot.service` stops the services, snapshots each state subvolume into
# `directory` as `<name>-<UTC time>-<subvolume name>`, and starts the services again.
# `state-snapshot-expire.timer` deletes these snapshots once they are `expireAfterDays` old,
# and `state-snapshot-prune.service` deletes all of them at once. An Amp runner starts the
# snapshot and prune units through its unit rules (./amp-runner.nix), behind a prompt.
#
# Expiry and pruning delete only this unit's snapshots: entries in `directory` named
# `<name>-*` that are read-only subvolumes snapshotted from one of the current state
# subvolumes (their parent UUID). `btrfs subvolume delete` does not recurse, so nothing else
# is ever deleted.
#
# Each state directory must be its own subvolume, so a snapshot holds only that state and
# never pins deleted media. The snapshot unit fails until it is; convert a directory once,
# with its services stopped:
#   btrfs subvolume create <dir>.new && cp -a --reflink=always <dir>/. <dir>.new/ &&
#     chown --reference=<dir> <dir>.new && chmod --reference=<dir> <dir>.new &&
#     mv <dir> <dir>.pre-subvolume && mv <dir>.new <dir>
# then delete `<dir>.pre-subvolume` once the services work.
#
# To roll back to a snapshot: stop the services, `mv <dir> <dir>.broken`, then
# `btrfs subvolume snapshot <snapshot> <dir>`, deploy a configuration with the old package and
# start the services.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.stateSnapshot;
  subvolumes = lib.escapeShellArgs cfg.subvolumes;
  services = lib.escapeShellArgs cfg.services;
  runtimeInputs = [
    pkgs.btrfs-progs
    pkgs.coreutils
    pkgs.gawk
    pkgs.systemd
  ];
  snapshot = pkgs.writeShellApplication {
    name = "state-snapshot";
    inherit runtimeInputs;
    text = ''
      subvolumes=(${subvolumes})
      for subvolume in "''${subvolumes[@]}"; do
        if [ "$(stat -f -c %T "$subvolume")" != btrfs ] || [ "$(stat -c %i "$subvolume")" != 256 ]; then
          echo "$subvolume is not a btrfs subvolume; convert it first (modules/state-snapshot.nix)." >&2
          exit 1
        fi
      done
      install -d -m 0700 ${lib.escapeShellArg cfg.directory}
      stamp=$(date -u +%Y%m%dT%H%M%SZ)
      trap 'systemctl start ${services}' EXIT
      systemctl stop ${services}
      for subvolume in "''${subvolumes[@]}"; do
        btrfs subvolume snapshot -r "$subvolume" ${lib.escapeShellArg "${cfg.directory}/${cfg.name}"}-"$stamp-$(basename "$subvolume")"
      done
    '';
  };
  # Deletes this unit's snapshots that are at least $1 days old.
  prune = pkgs.writeShellApplication {
    name = "state-snapshot-prune";
    inherit runtimeInputs;
    text = ''
      max_age=$(( $1 * 86400 ))
      now=$(date +%s)
      sources=" "
      subvolumes=(${subvolumes})
      for subvolume in "''${subvolumes[@]}"; do
        if [ "$(stat -c %i "$subvolume")" = 256 ]; then
          sources+="$(btrfs subvolume show "$subvolume" | awk '$1 == "UUID:" { print $2 }') "
        fi
      done
      for snapshot in ${lib.escapeShellArg "${cfg.directory}/${cfg.name}"}-*; do
        if [ ! -d "$snapshot" ] || [ -L "$snapshot" ] || [ "$(stat -c %i "$snapshot")" != 256 ] ||
          [ "$(btrfs property get -ts "$snapshot" ro)" != ro=true ]; then
          continue
        fi
        info=$(btrfs subvolume show "$snapshot")
        parent=$(awk '$1 == "Parent" && $2 == "UUID:" { print $3 }' <<< "$info")
        case "$sources" in *" $parent "*) ;; *) continue ;; esac
        created=$(date -d "$(awk '$1 == "Creation" && $2 == "time:" { $1 = $2 = ""; print }' <<< "$info")" +%s)
        if [ $(( now - created )) -ge "$max_age" ]; then
          btrfs subvolume delete "$snapshot"
        fi
      done
    '';
  };
  pruneService = days: {
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe prune} ${toString days}";
    };
  };
in
{
  options.local.stateSnapshot = {
    enable = lib.mkEnableOption "read-only btrfs snapshots of service state";
    name = lib.mkOption {
      type = lib.types.strMatching "[a-z][a-z0-9-]*";
      description = "Prefix of the snapshots' names.";
    };
    directory = lib.mkOption {
      type = lib.types.str;
      description = "Where snapshots go, on the same btrfs file system as the subvolumes.";
    };
    subvolumes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "The state subvolumes to snapshot, with distinct directory names.";
    };
    services = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Units to stop while snapshotting and start again afterwards.";
    };
    expireAfterDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 14;
      description = "Age at which the timer deletes a snapshot.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.allUnique (map baseNameOf cfg.subvolumes);
        message = "local.stateSnapshot.subvolumes need distinct directory names.";
      }
    ];
    systemd.services.state-snapshot = {
      description = "Snapshot ${cfg.name} state";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe snapshot;
      };
    };
    systemd.services.state-snapshot-prune = pruneService 0 // {
      description = "Delete all ${cfg.name} state snapshots";
    };
    systemd.services.state-snapshot-expire = pruneService cfg.expireAfterDays // {
      description = "Delete ${cfg.name} state snapshots older than ${toString cfg.expireAfterDays} days";
    };
    systemd.timers.state-snapshot-expire = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };
  };
}
