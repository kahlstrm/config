{ pkgs }:
let
  inherit (pkgs) lib;
  hostAddress = "192.168.1.1";
  guestAddress = "192.168.1.2";
  otherAddress = "192.168.1.3";
  cache = "http://${hostAddress}:5000";
  address = ip: {
    virtualisation.vlans = [ 1 ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = ip;
        prefixLength = 24;
      }
    ];
    environment.systemPackages = [ pkgs.curl ];
    nix.settings.experimental-features = [ "nix-command" ];
  };
  # Built at run time on the host, so neither client has it.
  hostOnly = pkgs.writeText "host-only.nix" ''
    derivation {
      name = "host-only";
      system = "${pkgs.stdenv.hostPlatform.system}";
      builder = (builtins.storePath "${pkgs.bash}") + "/bin/bash";
      args = [ "-c" "echo built > $out" ];
      # Like a NixOS toplevel: Nix builds it locally unless told to always substitute.
      allowSubstitutes = false;
    }
  '';
in
pkgs.testers.runNixOSTest {
  name = "agent-cache";
  nodes = {
    host =
      { lib, ... }:
      {
        imports = [
          ../modules/agents/vm/cache.nix
          (address hostAddress)
        ];
        # Stand-ins for the host's agent VM declarations; a VM without deployment needs no warm-up.
        options.local.agentVMs = lib.mkOption { type = lib.types.attrs; };
        options.microvm.vms = lib.mkOption { type = lib.types.attrs; };
        config = {
          local.agentVMs.guest.network.guestAddress = guestAddress;
          microvm.vms.guest.evaluatedConfig.config.local.agentEnvironment.deploy.enable = false;
          local.agentVMCache.enable = true;
          # Only the socket's allow-list keeps other machines out.
          networking.firewall.allowedTCPPorts = [ 5000 ];
          system.extraDependencies = [ hostOnly ];
        };
      };
    guest = {
      imports = [ (address guestAddress) ];
      nix.settings.substituters = lib.mkForce [ "${cache}?trusted=true" ];
    };
    other = address otherAddress;
  };
  testScript = ''
    start_all()
    host.wait_for_unit("harmonia.socket")
    host.wait_for_unit("multi-user.target")
    guest.wait_for_unit("multi-user.target")
    other.wait_for_unit("multi-user.target")
    guest.wait_until_succeeds("curl --fail --max-time 5 ${cache}/nix-cache-info")
    guest.succeed("curl --fail --max-time 5 ${cache}/nix-cache-info | grep -x 'Priority: 30'")
    other.fail("curl --max-time 5 ${cache}/nix-cache-info")

    path = host.succeed("nix eval --impure --raw --file ${hostOnly} outPath").strip()
    poll = f"nix path-info --option narinfo-cache-negative-ttl 0 --store '${cache}?trusted=true' {path}"
    # A miss before the host builds it does not hide the path once it is there.
    guest.fail(poll)
    host.succeed("nix-build --no-out-link ${hostOnly}")
    guest.succeed(poll)

    # Unsigned paths are refused unless the substituter is trusted.
    download_only = "--option always-allow-substitutes true --max-jobs 0"
    guest.fail(f"nix-store --realise {path} {download_only} --option substituters ${cache}")
    guest.succeed(f"nix-store --realise {path} {download_only}")
    guest.succeed(f"grep -x built {path}")
  '';
}
