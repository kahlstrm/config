{ pkgs, inputs }:
let
  host = inputs.self.nixosConfigurations.pannu.config;
  vmService = host.systemd.services."microvm@agents";
  runnerStorage = host.systemd.services.amp-runner-storage;
  runner = host.systemd.services.amp-runner;
  # Every VM's disk images on pannu, so a new VM is covered too.
  images = pkgs.lib.concatMap (
    name: map (volume: volume.image) host.microvm.vms.${name}.evaluatedConfig.config.microvm.volumes
  ) (builtins.attrNames host.microvm.vms);
in
pkgs.testers.runNixOSTest {
  name = "agent-storage";
  nodes.host = {
    imports = [
      {
        systemd.services = pkgs.lib.optionalAttrs (host.systemd.services ? agent-storage) {
          agent-storage = {
            inherit (host.systemd.services.agent-storage)
              requires
              after
              before
              script
              ;
            serviceConfig.Type = host.systemd.services.agent-storage.serviceConfig.Type;
          };
        };
      }
    ];
    systemd.services.amp-runner-storage = {
      inherit (runnerStorage)
        wants
        after
        wantedBy
        path
        script
        ;
      serviceConfig = {
        inherit (runnerStorage.serviceConfig) Type RemainAfterExit;
      };
    };
    # pannu's runner unit, with a command that records each start in its home in place of amp.
    systemd.services.amp-runner = {
      inherit (runner) wants after;
      environment.HOME = runner.environment.HOME;
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        inherit (runner.serviceConfig)
          User
          Group
          WorkingDirectory
          StateDirectory
          StateDirectoryMode
          NoNewPrivileges
          ProtectSystem
          ProtectHome
          PrivateTmp
          ;
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''echo started >> "$HOME/runner-starts"'';
    };
    users.groups.kvm = { };
    users.users.microvm = {
      isSystemUser = true;
      group = "kvm";
    };
    users.groups.amp = { };
    # pannu's amp with its groups, so a group that opens the VMs' disks fails this test.
    users.users.amp = {
      isSystemUser = true;
      group = "amp";
      inherit (host.users.users.amp) extraGroups;
    };
    # The runner's state on the root disk from before the move.
    systemd.tmpfiles.rules =
      builtins.filter (rule: pkgs.lib.hasInfix "/mnt/agents" rule) host.systemd.tmpfiles.rules
      ++ [
        "d /var/lib/amp-runner 0700 amp amp -"
        "f /var/lib/amp-runner/old-state 0600 amp amp - state"
      ];
    virtualisation.fileSystems."/mnt/agents" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [
        "nofail"
        "mode=0755"
        "uid=0"
        "gid=0"
        "x-systemd.requires=agent-storage-delay.service"
      ];
    };
    systemd.services.agent-storage-delay = {
      serviceConfig.Type = "oneshot";
      script = ''
        touch /run/agent-storage-waiting
        until test -e /run/release-agent-storage; do sleep 0.1; done
      '';
    };
    systemd.services.agent-network = {
      serviceConfig.Type = "oneshot";
      script = "true";
    };
    systemd.services."microvm@agents" = {
      inherit (vmService) requires after;
      unitConfig.RequiresMountsFor = vmService.unitConfig.RequiresMountsFor;
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "microvm";
      };
      # Every VM's images, as the VMs' own user creates them.
      script = ''
        touch ${pkgs.lib.escapeShellArgs images}
      '';
    };
  };
  testScript = ''
    images = ${builtins.toJSON images}

    host.start()
    host.wait_for_unit("systemd-tmpfiles-setup.service")
    host.wait_until_succeeds("test -e /run/agent-storage-waiting")
    host.fail("mountpoint -q /mnt/agents")
    host.fail("test -e /mnt/agents/home.img")
    host.fail("systemctl is-active amp-runner.service")
    host.succeed("touch /run/release-agent-storage")
    host.wait_until_succeeds("mountpoint -q /mnt/agents")
    host.wait_until_succeeds("test -e ${builtins.head images}", timeout=15)
    assert host.succeed("stat -c '%U:%G' /mnt/agents").strip() == "microvm:kvm"
    host.succeed("su -s /bin/sh microvm -c 'touch /mnt/agents/another-disk.img'")

    # The runner starts on /mnt/agents/amp, which carries over its earlier state.
    host.wait_for_unit("amp-runner.service")
    assert host.succeed("findmnt -n -o SOURCE /var/lib/amp-runner").strip().endswith("[/amp]")
    options = host.succeed("findmnt -n -o OPTIONS /var/lib/amp-runner").strip().split(",")
    assert "nodev" in options and "nosuid" in options, options
    assert host.succeed("stat -c '%U:%G %a' /mnt/agents/amp").strip() == "amp:amp 700"
    assert host.succeed("cat /mnt/agents/amp/old-state").strip() == "state"
    assert host.succeed("stat -c '%U' /mnt/agents/amp/old-state").strip() == "amp"
    assert host.succeed("cat /mnt/agents/amp/runner-starts").strip() == "started"
    host.succeed("su -s /bin/sh amp -c 'touch /var/lib/amp-runner/lab-disk.qcow2'")
    host.succeed("test -e /mnt/agents/amp/lab-disk.qcow2")

    # amp cannot list the partition or open any VM's disks.
    host.fail("su -s /bin/sh amp -c 'ls /mnt/agents'")
    host.fail("su -s /bin/sh amp -c 'touch /mnt/agents/amp-file'")
    for path in images:
        host.succeed(f"test -e {path}")
        host.fail(f"su -s /bin/sh amp -c 'test -r {path}'")
        host.fail(f"su -s /bin/sh amp -c 'test -w {path}'")

    # Without the partition, the runner stays on the root disk and nothing fails.
    host.succeed("systemctl stop amp-runner.service")
    host.succeed("umount /var/lib/amp-runner")
    host.succeed("systemctl stop microvm@agents.service")
    host.succeed("umount /mnt/agents")
    host.succeed("systemctl mask --runtime mnt-agents.mount")
    host.succeed("systemctl restart amp-runner-storage.service")
    host.fail("mountpoint -q /var/lib/amp-runner")
    host.succeed("journalctl -u amp-runner-storage.service | grep -q 'runner stays on the root disk'")
    host.succeed("systemctl start amp-runner.service")
    assert host.succeed("cat /var/lib/amp-runner/runner-starts").strip() == "started"
    host.fail("systemctl is-failed amp-runner-storage.service amp-runner.service")
  '';
}
