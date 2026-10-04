{ pkgs, inputs }:
let
  guestPkgs = import inputs.nixpkgs-unstable-nixos {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in
guestPkgs.testers.runNixOSTest {
  name = "agent-guest";
  nodes.guest = { lib, config, ... }: {
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
    environment.etc."test-gh-package".text = "${config.local.agentGithub.package}/bin/gh";
    programs.git.config.url."file:///home/agent/workspace-fixture".insteadOf =
      "https://github.com/kahlstrm/config.git";
    systemd.services.agent-workspace.preStart = ''
      mkdir -p /home/agent/workspace-fixture
      git -C /home/agent/workspace-fixture init
      echo 'workspace fixture' > /home/agent/workspace-fixture/README
      git -C /home/agent/workspace-fixture add README
      git -C /home/agent/workspace-fixture commit --allow-empty -m fixture
    '';
  };
  testScript = ''
    guest.start()
    guest.wait_for_unit("t3code.service")
    guest.wait_for_unit("agent-workspace.service")
    guest.succeed("su - agent -c 'test -f ~/config/README && test -w ~/config/.git/config'")
    guest.succeed("su - agent -c 'test $(git -C ~/config remote get-url --push origin) = https://github.com/kahlstrm-agents/config.git'")
    guest.succeed("su - agent -c 'test $(git -C ~/config config remote.upstream.url) = https://github.com/kahlstrm/config.git'")
    guest.succeed("su - agent -c 'git -C ~/config config test.marker retained'")
    guest.succeed("systemctl restart agent-workspace")
    guest.succeed("su - agent -c 'test $(git -C ~/config config test.marker) = retained'")
    guest.wait_until_succeeds("curl --fail --max-time 2 --output /dev/null http://10.83.0.2:3773/")
    guest.succeed("test $(curl --silent --output /dev/null --write-out '%{http_code}' http://10.83.0.2:3773/ws) = 401")
    guest.succeed("su - agent -c 'codex --version && claude --version && opencode --version'")
    guest.succeed("su - agent -c 'test -r ~/.codex/AGENTS.md && test -r ~/.claude/CLAUDE.md && test -r ~/.config/opencode/AGENTS.md'")
    guest.succeed("jq -e '.isolation.hostShares == [] and .github.enabled == true' /etc/agent-environment.json")
    guest.succeed("git config --system --get credential.useHttpPath | grep true")
    guest.fail("su - agent -c 'gh-agent other/config pr list'")
    guest.succeed("su - agent -c 'gh --version'")
    guest.fail("su - agent -c 'gh auth login'")
    guest.fail("su - agent -c 'gh pr list -R other/config'")
    guest.succeed("test $(readlink -f /run/current-system/sw/bin/gh) = $(cat /etc/test-gh-package)")
    guest.succeed("pid=$(systemctl show t3code -p MainPID --value); t3path=$(tr '\\0' '\\n' < /proc/$pid/environ | sed -n 's/^PATH=//p'); test $(PATH=$t3path command -v gh) = $(cat /etc/test-gh-package)")
    guest.fail("su - agent -c 'sudo -n true'")
  '';
}
