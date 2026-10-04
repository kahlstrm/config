{ pkgs, inputs }:
let
  guestPkgs = import inputs.nixpkgs-unstable-nixos {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in
guestPkgs.testers.runNixOSTest {
  name = "agent-guest";
  nodes.guest = { lib, ... }: {
    imports = [
      ../modules/agent-vm
      ../modules/agent-github
      inputs.agenix.nixosModules.default
    ];
    virtualisation.vlans = [ 1 ];
    virtualisation.memorySize = 4096;
    local.agentGithub = {
      enable = true;
      apps.fork = {
        id = "1";
        installationId = "2";
        keyFile = "/run/test-fork.pem";
      };
      apps.upstream = {
        id = "3";
        installationId = "4";
        keyFile = "/run/test-pr.pem";
      };
    };
    systemd.network.networks."10-agent".matchConfig = lib.mkForce { Name = "eth1"; };
  };
  testScript = ''
    guest.start()
    guest.wait_for_unit("t3code.service")
    guest.wait_until_succeeds("curl --fail --max-time 2 --output /dev/null http://10.83.0.2:3773/")
    guest.succeed("test $(curl --silent --output /dev/null --write-out '%{http_code}' http://10.83.0.2:3773/ws) = 401")
    guest.succeed("su - agent -c 'codex --version && claude --version && opencode --version'")
    guest.succeed("su - agent -c 'test -r ~/.codex/AGENTS.md && test -r ~/.claude/CLAUDE.md && test -r ~/.config/opencode/AGENTS.md'")
    guest.succeed("jq -e '.isolation.hostShares == [] and .github.enabled == true' /etc/agent-environment.json")
    guest.succeed("git config --system --get credential.useHttpPath | grep true")
    guest.fail("su - agent -c 'gh-agent other/config pr list'")
    guest.fail("su - agent -c 'sudo -n true'")
  '';
}
