{ pkgs, inputs }:
let
  host = inputs.self.nixosConfigurations.pannu.config;
  vmService = host.systemd.services."microvm@agents";
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
    users.groups.kvm = { };
    users.users.microvm = {
      isSystemUser = true;
      group = "kvm";
    };
    systemd.tmpfiles.rules = builtins.filter (
      rule: pkgs.lib.hasInfix "/mnt/agents" rule
    ) host.systemd.tmpfiles.rules;
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
      script = ''
        touch /mnt/agents/test-disk.img
      '';
    };
  };
  testScript = ''
    host.start()
    host.wait_for_unit("systemd-tmpfiles-setup.service")
    host.wait_until_succeeds("test -e /run/agent-storage-waiting")
    host.fail("mountpoint -q /mnt/agents")
    host.fail("test -e /mnt/agents/test-disk.img")
    host.succeed("touch /run/release-agent-storage")
    host.wait_until_succeeds("mountpoint -q /mnt/agents")
    host.wait_until_succeeds("test -e /mnt/agents/test-disk.img", timeout=15)
    assert host.succeed("stat -c '%U:%G' /mnt/agents").strip() == "microvm:kvm"
    host.succeed("su -s /bin/sh microvm -c 'touch /mnt/agents/another-disk.img'")
  '';
}
