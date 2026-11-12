# modules/backup.nix: with credentials installed once as encrypted systemd credentials, a host
# backs up to zima's chrooted SFTP repository and off-site; zima creates both repositories;
# losing zima still leaves the off-site backup; the cluster's drop is write-only; zima's
# checks and restore check report through node-exporter metrics; state behind a DynamicUser
# symlink is backed up from its target; and zima's mirror copies a host's snapshots down.
{ pkgs }:
let
  sshKeys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  key = sshKeys.snakeOilEd25519PrivateKey;
  # What the cluster's jobs drop: a Pocket ID export with a user and keys, and the Terraform state
  # state encrypted with sops.
  drops = pkgs.runCommand "backup-test-drops" { nativeBuildInputs = [ pkgs.zip ]; } ''
    mkdir $out && cd $out
    echo '{"tables": {"users": [{"id": "1"}], "kv": [{"key": "k"}]}}' > database.json
    zip -q pocket-id-export.zip database.json && rm database.json
    echo '{"tables": {"users": [], "kv": []}}' > database.json
    zip -q empty-export.zip database.json && rm database.json
    echo '{"data": "ENC[AES256_GCM,data:x]", "sops": {"age": [{"recipient": "ssh-ed25519 x"}]}}' > terraform-state.tar.sops
  '';
  backupHost =
    { lib, nodes, ... }:
    {
      imports = [ ../modules/backup.nix ];
      programs.ssh.knownHosts."zima.kalski.xyz".publicKey = lib.mkForce sshKeys.snakeOilEd25519PublicKey;
      networking.extraHosts = "${nodes.zima.networking.primaryIPAddress} zima.kalski.xyz";
      environment.systemPackages = [ pkgs.sqlite ];
      # The host key the restore check expects in each host's snapshot; on zima, also sshd's.
      environment.etc."ssh/ssh_host_ed25519_key" = {
        source = key;
        mode = "0600";
      };
      local.backup.paths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };
in
pkgs.testers.runNixOSTest {
  name = "backup";
  nodes.zima =
    { lib, ... }:
    {
      imports = [ backupHost ];
      services.openssh.enable = true;
      # zima's host key is the one the hosts pin.
      services.openssh.hostKeys = lib.mkForce [
        {
          type = "ed25519";
          path = "/etc/ssh/ssh_host_ed25519_key";
        }
      ];
      users.users.backup-drop.openssh.authorizedKeys.keys = lib.mkForce [
        "restrict ${sshKeys.snakeOilEd25519PublicKey}"
      ];
      local.backup = {
        enable = true;
        drop.enable = true;
        server = {
          enable = true;
          sources = [
            "zima"
            "pannu"
          ];
          mirrorHosts = [ "pannu" ];
          dropHosts = [ "zima" ];
        };
        paths = [ "/var/lib/zima-state" ];
      };
      systemd.tmpfiles.rules = [ "f /var/lib/zima-state/settings 0600 root root - zima" ];
    };
  # The Storage Box: a plain SFTP account. It also stands in for the cluster's upload job.
  nodes.storagebox =
    { nodes, ... }:
    {
      networking.extraHosts = "${nodes.zima.networking.primaryIPAddress} zima.kalski.xyz";
      services.openssh.enable = true;
      users.users.restic = {
        isNormalUser = true;
        openssh.authorizedKeys.keys = [ sshKeys.snakeOilEd25519PublicKey ];
      };
    };
  nodes.pannu = {
    imports = [ backupHost ];
    local.backup = {
      enable = true;
      paths = [ "/var/lib/private/app" ];
      exclude = [ "/var/lib/private/app/cache" ];
    };
    # An app whose state is behind a DynamicUser symlink, like Bambuddy on pannu, with a
    # SQLite database in WAL mode and a write still in the WAL.
    systemd.services.app = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        DynamicUser = true;
        StateDirectory = "app";
      };
      script = ''
        ${pkgs.sqlite}/bin/sqlite3 "$STATE_DIRECTORY/app.db" 'PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE t(x); INSERT INTO t VALUES (42);'
        mkdir -p "$STATE_DIRECTORY/cache" && echo junk > "$STATE_DIRECTORY/cache/junk"
      '';
    };
  };

  testScript = ''
    import json

    def snapshots(machine, repository, host):
        return json.loads(machine.succeed(f"restic-backup {repository} snapshots --json --host {host}"))

    def metrics(name):
        return zima.succeed(f"cat /var/lib/prometheus-node-exporter-text/{name}.prom")

    def install_credentials(machine):
        machine.succeed(
          "install -d -m 0700 /etc/credstore.encrypted",
          "printf 'test-password\\n' | systemd-creds encrypt --name=backup-password - /etc/credstore.encrypted/backup-password",
          "systemd-creds encrypt --name=backup-ssh-key ${key} /etc/credstore.encrypted/backup-ssh-key",
          "printf 'sftp:restic@storagebox:/home/restic/repo\\n' | systemd-creds encrypt --name=backup-offsite - /etc/credstore.encrypted/backup-offsite",
        )

    zima_repo = "-r sftp:restic@zima.kalski.xyz:/repo"
    offsite = "-r sftp:restic@storagebox:/home/restic/repo"
    # ssh refuses a private key that others can read, as the store's copy is.
    drop = "sftp -F /dev/null -i /root/key -o StrictHostKeyChecking=no -b - backup-drop@zima.kalski.xyz"

    start_all()
    for machine in [zima, storagebox, pannu]:
        machine.wait_for_unit("multi-user.target")
        machine.succeed("install -m 0600 ${key} /root/key")

    with subtest("without credentials, nothing is set up and the backup says why"):
        zima.succeed("systemctl is-active backup-server.service")
        zima.fail("test -e /var/lib/restic/repo/config")
        pannu.fail("systemctl start backup.service")
        assert "credentials are not installed" in pannu.succeed("journalctl -u backup.service")

    with subtest("installing the credentials authorizes the key and creates zima's repository"):
        install_credentials(zima)
        install_credentials(pannu)
        zima.succeed("systemctl restart backup-server.service")
        zima.succeed("test -e /var/lib/restic/repo/config")
        zima.succeed("test -z \"$(find /var/lib/restic/repo ! -user restic)\"")

    with subtest("the drop takes uploads and replacements but gives nothing back"):
        storagebox.succeed(f"printf 'put ${drops}/empty-export.zip pocket-id-export.zip.tmp\\nrename pocket-id-export.zip.tmp pocket-id-export.zip\\n' | {drop}")
        for file in ["pocket-id-export.zip", "terraform-state.tar.sops"]:
            storagebox.succeed(f"printf 'put ${drops}/{file} {file}.tmp\\nrename {file}.tmp {file}\\n' | {drop}")
        storagebox.fail(f"echo 'get terraform-state.tar.sops /tmp/roots' | {drop}")
        storagebox.fail(f"echo 'rm terraform-state.tar.sops' | {drop}")
        zima.succeed("cmp /var/lib/backup-drop/incoming/pocket-id-export.zip ${drops}/pocket-id-export.zip")

    with subtest("zima creates the off-site repository, and both hold each host's backup"):
        pannu.succeed("test -L /var/lib/app")
        zima.succeed("systemctl start backup.service")
        pannu.succeed("systemctl start backup.service")
        for repository in [zima_repo, offsite]:
            assert len(snapshots(zima, repository, "zima")) == 1, repository
            assert len(snapshots(zima, repository, "pannu")) == 1, repository
        zima.succeed("test -z \"$(find /var/lib/restic/repo ! -user restic)\"")

    with subtest("restic-backup run by hand imports the credentials itself"):
        pannu.succeed(f"cd /tmp && restic-backup {zima_repo} snapshots")

    with subtest("the backup key reaches only the repository, over SFTP"):
        sftp = "sftp -F /dev/null -i /root/key -o BatchMode=yes -b -"
        listing = pannu.succeed(f"echo 'ls /' | {sftp} restic@zima.kalski.xyz")
        assert "/repo" in listing and "/etc" not in listing, listing
        pannu.fail(f"echo 'get /etc/passwd /tmp/passwd' | {sftp} restic@zima.kalski.xyz")

    with subtest("the snapshot restores a consistent copy of the database, without the cache"):
        pannu.succeed(f"restic-backup {offsite} restore latest --host pannu --target /tmp/restore")
        pannu.succeed("test ! -e /tmp/restore/var/lib/private/app/app.db")
        pannu.succeed("test ! -e /tmp/restore/var/lib/private/app/cache/junk")
        copy = "/tmp/restore/var/lib/backup/sqlite/var/lib/private/app/app.db"
        assert pannu.succeed(f"sqlite3 'file:{copy}?immutable=1' 'PRAGMA integrity_check; SELECT x FROM t'").split() == ["ok", "42"]

    with subtest("the checks report each repository, source and dropped file"):
        zima.succeed("systemctl start backup-check.service")
        report = metrics("backup")
        for repository in ["zima", "offsite"]:
            assert f'backup_repository_up{{repository="{repository}"}} 1' in report, report
            for source in ["zima", "pannu"]:
                assert f'backup_snapshot_newest_timestamp_seconds{{repository="{repository}",source="{source}"}} 0' not in report, report
            for file in ["pocket-id-export.zip", "terraform-state.tar.sops"]:
                assert f'backup_file_mtime_seconds{{repository="{repository}",source="zima",file="{file}"}} 0' not in report, report
        # grep -q would stop reading at the first match, and curl would then fail on the closed pipe.
        zima.succeed("curl -sf localhost:9100/metrics | grep '^backup_repository_up' >/dev/null")

    with subtest("the restore check passes, and fails on an export without users"):
        zima.succeed("systemctl start backup-restore-check.service")
        assert 'backup_restore_check_success{repository="zima"} 1' in metrics("backup-restore")
        assert 'backup_restore_check_success{repository="offsite"} 1' in metrics("backup-restore")
        storagebox.succeed(f"printf 'put ${drops}/empty-export.zip pocket-id-export.zip.tmp\\nrename pocket-id-export.zip.tmp pocket-id-export.zip\\n' | {drop}")
        zima.succeed("systemctl start backup.service")
        zima.succeed("systemctl start backup-restore-check.service")
        assert 'backup_restore_check_success{repository="zima"} 0' in metrics("backup-restore")

    with subtest("with zima down, the host still backs up off-site and reports the failure"):
        zima.succeed("systemctl stop sshd.service")
        pannu.fail("systemctl start backup.service")
        assert len(snapshots(zima, offsite, "pannu")) == 2
        zima.succeed("systemctl start sshd.service")
        assert len(snapshots(zima, zima_repo, "pannu")) == 1

    with subtest("zima's mirror copies a host's latest off-site snapshot down"):
        ids = " ".join(snapshot["id"] for snapshot in snapshots(zima, zima_repo, "pannu"))
        zima.succeed(f"restic-backup {zima_repo} forget {ids}")
        zima.succeed("systemctl start backup-mirror.service")
        assert len(snapshots(zima, zima_repo, "pannu")) == 1

    with subtest("pruning succeeds and reports it"):
        zima.succeed("systemctl start backup-prune.service")
        assert "backup_prune_last_success_timestamp_seconds" in metrics("backup-prune")
  '';
}
