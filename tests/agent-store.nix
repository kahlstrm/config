{ pkgs }:
let
  seed = pkgs.callPackage ../modules/agents/vm/store-seed-package.nix { };
  oldDependency = pkgs.writeText "old-image-only" "old dependency";
  deployment = pkgs.writeShellScriptBin "guest-deployment" ''
    cat ${oldDependency}
  '';
  interruptedSeed = pkgs.writeShellApplication {
    name = "interrupted-agent-store-seed";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      cp() {
        ${pkgs.coreutils}/bin/cp "$@"
        if [ ! -e "$persistent/interrupted-once" ]; then
          touch "$persistent/interrupted-once"
          sync -f "$persistent"
          echo agent-store-test-copy-interrupted
          sleep infinity
        fi
      }
    ''
    + builtins.readFile ../modules/agents/vm/store-seed.sh;
  };
  disk =
    pkgs.runCommand "agent-store-test.qcow2"
      {
        nativeBuildInputs = [
          pkgs.e2fsprogs
          pkgs.qemu
        ];
      }
      ''
        truncate -s 2G disk.raw
        mkfs.ext4 -m 0 -L agent-store-test disk.raw
        qemu-img convert -f raw -O qcow2 disk.raw "$out"
      '';
  node = image: { lib, ... }: {
    imports = [
      ../modules/agents/vm/store.nix
      ../modules/agents/environment/store-repair.nix
    ];
    system.stateVersion = "26.05";
    users.users.agent.isNormalUser = true;
    boot.initrd.availableKernelModules = [ "virtio_blk" ];
    fileSystems."/" = {
      device = "tmpfs";
      fsType = "tmpfs";
    };
    fileSystems."/nix" = {
      device = "/dev/disk/by-id/virtio-agent-store-test";
      fsType = "ext4";
      neededForBoot = true;
    };
    environment.etc."boot-image".text = image;
    environment.systemPackages = [
      seed
      pkgs.bash
      pkgs.coreutils
    ];
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
      writableStore = false;
      useDefaultFilesystems = false;
      fileSystems = lib.mkForce { };
      diskImage = null;
      additionalPaths = lib.optionals (image == "A") [ deployment ];
      qemu.options = [
        "-drive file=$AGENT_STORE_TEST_DISK,if=none,id=agent-store-test,format=qcow2"
        "-device virtio-blk-pci,drive=agent-store-test,serial=agent-store-test"
      ];
    };
    boot.initrd.systemd.services.agent-store-seed.serviceConfig.ExecStart = lib.mkIf (image == "A") (
      lib.mkForce "${lib.getExe interruptedSeed} /sysroot/nix/.ro-store /sysroot/nix"
    );
    boot.initrd.systemd.storePaths = lib.optional (image == "A") interruptedSeed;
  };
in
pkgs.testers.runNixOSTest {
  name = "agent-store";
  # Otherwise the driver preloads the A-only deployment into image B as well.
  includeTestScriptReferences = false;
  nodes.image_a = node "A";
  nodes.image_b = node "B";
  testScript = ''
    import os
    import subprocess
    from pathlib import Path

    disk = Path.cwd() / "persistent-agent-store.qcow2"
    subprocess.run(["cp", "${disk}", str(disk)], check=True)
    disk.chmod(0o600)
    os.environ["AGENT_STORE_TEST_DISK"] = str(disk)

    with subtest("Recover an interrupted first-boot copy"):
        image_a.start()
        image_a.wait_for_console_text("agent-store-test-copy-interrupted")
        image_a.crash()
        image_a.start()
        image_a.wait_for_unit("multi-user.target")
        image_a.succeed("test ! -e /nix/.agent-store-seed")

    with subtest("Preserve a guest deployment across boot image replacement"):
        image_a.succeed("mkdir -p /nix/var/nix/profiles/agent-deploy")
        image_a.succeed("nix-env --profile /nix/var/nix/profiles/agent-deploy/current --set ${deployment}")
        image_a.succeed('test "$(/nix/var/nix/profiles/agent-deploy/current/bin/guest-deployment)" = "old dependency"')
        image_a.shutdown()
        image_b.start()
        image_b.wait_for_unit("multi-user.target")
        image_b.succeed("test $(cat /etc/boot-image) = B")
        image_b.succeed("test ! -e /nix/.ro-store/${builtins.baseNameOf oldDependency}")
        image_b.succeed("test ! -d /var/cache/agent-store-test")
        image_b.succeed("test $(findmnt -n -o FSTYPE /nix/store) = ext4")
        image_b.succeed('test "$(/nix/var/nix/profiles/agent-deploy/current/bin/guest-deployment)" = "old dependency"')
        image_b.succeed("nix-store --gc")
        image_b.succeed("nix-store --verify --check-contents")
        image_b.succeed('test "$(/nix/var/nix/profiles/agent-deploy/current/bin/guest-deployment)" = "old dependency"')
        image_b.succeed("nix-build --no-out-link --option substituters \"\" --expr 'derivation { name = \"offline-build\"; system = \"x86_64-linux\"; builder = \"${pkgs.bash}/bin/bash\"; args = [ \"-c\" \"echo built > $out\" ]; }'")

    with subtest("Disk exhaustion does not publish partial paths"):
        image_b.succeed("mkdir /run/space-seed; dd if=/dev/zero of=/run/space-seed/space-fixture bs=1M count=8")
        image_b.succeed("fallocate -l $(($(df -B1 --output=avail /nix | tail -1) - 65536)) /nix/fill")
        image_b.fail("agent-store-seed /run/space-seed /nix")
        image_b.succeed("test ! -e /nix/.rw-store/store/space-fixture")
        image_b.succeed('test "$(/nix/var/nix/profiles/agent-deploy/current/bin/guest-deployment)" = "old dependency"')
        image_b.succeed("rm /nix/fill; agent-store-seed /run/space-seed /nix")
        image_b.succeed("cmp /run/space-seed/space-fixture /nix/store/space-fixture; rm /nix/store/space-fixture")

    with subtest("Agents can request fixed repair without general root access"):
        image_b.wait_for_unit("polkit.service")
        image_b.fail("su - agent -c 'agent-store-repair /nix/store/arbitrary'")
        image_b.fail("su - agent -c 'systemctl --no-ask-password stop agent-store-repair.service'")
        image_b.fail("su - agent -c 'systemctl --no-ask-password start sshd.service'")
        repair_path = image_b.succeed("nix-store --add-text repair-fixture repairable").strip()
        image_b.succeed(f"nix copy --to file:///var/cache/agent-store-test {repair_path}")
        image_b.succeed(f"chmod u+w {repair_path}; echo corrupted > {repair_path}")
        image_b.succeed("su - agent -c agent-store-repair")
        image_b.wait_until_succeeds(f"test $(cat {repair_path}) = repairable")
        image_b.wait_until_succeeds("test $(systemctl show agent-store-repair -p ActiveState --value) = inactive")
        image_b.succeed("test $(systemctl show agent-store-repair -p Result --value) = success")
        image_b.succeed(f"test $(cat {repair_path}) = repairable")
        image_b.succeed("su - agent -c 'test -r /var/log/agent-store-repair/repair.log'")
        image_b.succeed("nix-store --verify --check-contents")
  '';
}
