{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "agent-store-repair";
  nodes.machine = {
    imports = [ ../modules/agents/environment/store-repair.nix ];
    users.users.agent.isNormalUser = true;
    nix.settings = {
      experimental-features = [ "nix-command" ];
      substituters = [ "file:///var/cache/agent-store-test" ];
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
        # Only the test VM's writable overlay is remounted to inject corruption.
        machine.succeed("mount -o remount,rw /nix/store")
        machine.succeed(f"chmod u+w {repair_path}; echo corrupted > {repair_path}")
        machine.succeed("mount -o remount,ro /nix/store")
        machine.fail("nix-store --verify --check-contents")
        machine.fail("su - agent -c 'nix-store --verify --check-contents --repair'")
        machine.succeed("su - agent -c agent-store-repair")
        machine.wait_for_unit("polkit.service")
        machine.wait_until_succeeds(f"test $(cat {repair_path}) = repairable")
        machine.wait_until_succeeds("test $(systemctl show agent-store-repair -p ActiveState --value) = inactive")
        machine.succeed("test $(systemctl show agent-store-repair -p Result --value) = success")
        machine.succeed("su - agent -c 'test -r /var/log/agent-store-repair/repair.log'")
        machine.succeed("nix-store --verify --check-contents")
  '';
}
