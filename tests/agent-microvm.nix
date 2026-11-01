# Boots a small guest through microvm.nix's own runner (microvm-run) with the
# shared agent VM modules, so CI covers what the NixOS test driver's VMs skip:
# the generated QEMU command line (q35, virtio-pci, aio=io_uring, -sandbox on),
# the start-up order (our preStart, then microvm.nix's volume creation, then
# QEMU) and the store seed from the read-only store disk onto the /nix volume.
{ pkgs, inputs }:
let
  inherit (pkgs) lib;
  # /nix holds the seeded closure (about 1.5 GiB) and the write burst.
  burstMiB = 1536;
  volumeSizes = {
    home = 256;
    var = 512;
    nix = 4 * 1024;
  };
  # Runs between microvm.nix's volume creation and the QEMU exec; its output
  # becomes extra QEMU arguments. It records what QEMU starts with and passes
  # through the test driver's console, monitor and QMP arguments.
  qemuStartHook = pkgs.writeShellScript "agent-microvm-qemu-start" ''
    for image in ${lib.concatMapStringsSep " " (name: "${name}.img") (lib.attrNames volumeSizes)}; do
      if [ -e "$image" ]; then
        ${pkgs.coreutils}/bin/stat -c "$image %s %b %B" "$image"
      else
        echo "$image missing"
      fi
    done > qemu-start-images
    echo "$AGENT_MICROVM_DRIVER_ARGS"
  '';
  guest =
    (inputs.nixpkgs-unstable-nixos.lib.nixosSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        inputs.microvm.nixosModules.microvm
        ../modules/agents/vm/guest.nix
        "${inputs.nixpkgs-unstable-nixos}/nixos/modules/testing/test-instrumentation.nix"
        (
          { lib, ... }:
          {
            # guest.nix publishes its settings to the agent environment; the full
            # environment is out of scope here, so accept them freely.
            options.local.agentEnvironment = lib.mkOption {
              type = lib.types.submodule { freeformType = lib.types.attrsOf lib.types.anything; };
            };
            config = {
              nixpkgs.overlays = [ inputs.microvm.overlays.default ];
              system.stateVersion = "26.05";
              local.agentEnvironment.user = "agent";
              local.agentVM = {
                name = "agents";
                settings = import ../modules/agents/vm/settings.nix;
                passwordlessSudo = false;
                inherit volumeSizes;
              };
              microvm = {
                vcpu = 2;
                mem = 2048;
                # The test sandbox has no tap; user networking keeps the agent NIC's MAC.
                interfaces = lib.mkForce [
                  {
                    type = "user";
                    id = "agent-net";
                    mac = (import ../modules/agents/vm/settings.nix).network.mac;
                  }
                ];
                extraArgsScript = "${qemuStartHook}";
              };
              # Report a stalled writer well within the write burst's timeout; test-instrumentation silences it.
              boot.kernel.sysctl."kernel.hung_task_timeout_secs" = lib.mkForce 60;
              documentation.enable = false;
            };
          }
        )
      ];
    }).config;
  runner = guest.microvm.declaredRunner;
  # The driver appends its console, monitor and QMP arguments to the start
  # command; microvm-run ignores arguments, so hand them to the start hook.
  # The guest's serial console already uses stdio.
  startGuest = pkgs.writeShellScript "start-agent-microvm" ''
    args=()
    while [ $# -gt 0 ]; do
      if [ "$1" = -serial ] && [ "''${2:-}" = stdio ]; then
        shift 2
        continue
      fi
      args+=("$1")
      shift
    done
    export AGENT_MICROVM_DRIVER_ARGS="''${args[*]}"
    exec ${runner}/bin/microvm-run
  '';
  imageBytes = lib.mapAttrs' (
    name: size: lib.nameValuePair "${name}.img" (size * 1024 * 1024)
  ) volumeSizes;
in
pkgs.testers.runNixOSTest {
  name = "agent-microvm";
  nodes = { };
  testScript = ''
    import json
    import re
    from datetime import timedelta

    script = open("${runner}/bin/microvm-run").read()
    with subtest("microvm.nix generates the command line pannu runs"):
        assert re.search(r"-M '?q35,", script), "not on q35"
        assert "virtio-blk-pci" in script and "virtio-net-pci" in script, "not virtio-pci"
        assert "aio=io_uring" in script, "no io_uring"
        assert re.search(r"'?-sandbox'? '?on", script), "no seccomp sandbox"

    guest = create_machine("${startGuest}", name="guest", keep_machine_state=True)
    images = json.loads('${builtins.toJSON imageBytes}')

    def check_images_at_qemu_start():
        report = (guest.state_dir / "qemu-start-images").read_text()
        guest.log(report)
        started = {fields[0]: fields[1:] for fields in map(str.split, report.splitlines())}
        assert started.keys() == images.keys(), report
        for image, expected in images.items():
            assert started[image] != ["missing"], f"QEMU started without {image}"
            size, blocks, block_size = map(int, started[image])
            assert size == expected, f"{image} is {size} bytes, expected {expected}"
            assert blocks * block_size >= expected, f"{image} was not fully allocated when QEMU started"

    filesystems = "for mountpoint in /home /var /nix; do findmnt -no SOURCE,UUID --mountpoint $mountpoint; done"

    # Machines from create_machine outlive the driver's cleanup; stop QEMU on failure.
    try:
        with subtest("A first start from empty images reserves every image before QEMU and seeds the store"):
            assert not any(guest.state_dir.glob("*.img"))
            guest.start()
            guest.wait_for_unit("multi-user.target")
            check_images_at_qemu_start()
            guest.succeed("journalctl -b -q -o cat -u agent-store-seed.service JOB_TYPE=start JOB_RESULT=done | grep -q .")
            guest.succeed("test ! -e /nix/.agent-store-seed")
            guest.succeed("for path in /nix/.ro-store/*; do test -e /nix/store/''${path##*/}; done")
            first = guest.succeed(filesystems)
            guest.succeed("echo kept > /home/marker")

        with subtest("A sustained write burst on /nix completes without stalled writers"):
            guest.log(guest.succeed("df -h /nix"))
            guest.succeed("dd if=/dev/urandom of=/nix/burst bs=1M count=${toString burstMiB} conv=fsync status=none", timeout=timedelta(minutes=5))
            guest.succeed("rm /nix/burst && sync")
            guest.fail("dmesg | grep 'blocked for more than'")

        with subtest("A second start keeps the same filesystems"):
            guest.shutdown()
            guest.start()
            guest.wait_for_unit("multi-user.target")
            check_images_at_qemu_start()
            assert guest.succeed(filesystems) == first, "filesystems changed"
            guest.succeed("test \"$(cat /home/marker)\" = kept")
            guest.shutdown()
    finally:
        guest.crash()
  '';
}
