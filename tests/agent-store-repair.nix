{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "agent-store-repair";
  nodes.machine = { lib, ... }: {
    imports = [ ../modules/agents/environment/store-repair.nix ];
    users.users.agent.isNormalUser = true;
    nix.settings = {
      experimental-features = [ "nix-command" ];
      substituters = lib.mkForce [ "file:///var/cache/agent-store-test" ];
      trusted-users = [ "root" ];
    };
    virtualisation = {
      memorySize = 2048;
      restrictNetwork = true;
      mountHostNixStore = false;
      useNixStoreImage = true;
      writableStore = true;
    };
  };
  testScript = ''
    from datetime import timedelta
    from pathlib import Path

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("dbus.service")

    with subtest("Repair grants no general root access"):
        machine.fail("su - agent -c 'agent-store-repair /nix/store/arbitrary'")
        machine.fail("su - agent -c 'systemctl --no-ask-password stop agent-store-repair.service'")
        machine.fail("su - agent -c 'systemctl --no-ask-password start sshd.service'")

    with subtest("An agent can restore corrupted contents from a configured cache"):
        machine.succeed("printf repairable > /run/repair-fixture")
        repair_path = machine.succeed("nix-store --add /run/repair-fixture").strip()
        machine.succeed(f"nix copy --to file:///var/cache/agent-store-test {repair_path}")
        backing_path = f"/nix/.rw-store/upper/{Path(repair_path).name}"
        machine.succeed(f"chmod u+w {backing_path}; echo corrupted > {backing_path}")
        machine.fail("nix-store --verify --check-contents")
        machine.fail("su - agent -c 'nix-store --verify --check-contents --repair'")
        machine.succeed("su - agent -c agent-store-repair")
        machine.wait_for_unit("polkit.service")
        try:
            machine.wait_until_succeeds(f"test $(cat {repair_path}) = repairable", timeout=timedelta(seconds=90))
            machine.wait_until_succeeds("test $(systemctl show agent-store-repair -p ActiveState --value) = inactive", timeout=timedelta(seconds=90))
            machine.succeed("test $(systemctl show agent-store-repair -p Result --value) = success")
            machine.succeed(f"test $(cat {repair_path}) = repairable")
        except Exception:
            for command in [
                "systemctl status --no-pager agent-store-repair",
                "cat /var/log/agent-store-repair/repair.log",
                "journalctl --no-pager -u agent-store-repair -u nix-daemon",
            ]:
                print(machine.execute(command)[1])
            raise
        machine.succeed("su - agent -c 'test -r /var/log/agent-store-repair/repair.log'")
        machine.succeed("nix-store --verify --check-contents")
  '';
}
