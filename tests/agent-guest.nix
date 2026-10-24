{ pkgs, inputs }:
let
  guestPkgs = import inputs.nixpkgs-unstable-nixos {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
  persistentGuest =
    inputs.self.nixosConfigurations.pannu.config.microvm.vms.agents.evaluatedConfig.config;
  dockerTestImage = guestPkgs.dockerTools.buildImage {
    name = "agent-docker-test";
    tag = "latest";
    copyToRoot = [ guestPkgs.busybox ];
    config.Cmd = [
      "/bin/echo"
      "container-ran"
    ];
  };
in
guestPkgs.testers.runNixOSTest {
  name = "agent-guest";
  nodes.guest = { lib, config, ... }: {
    imports = [
      ../modules/agents/environment
      inputs.agenix.nixosModules.default
    ];
    local.agentEnvironment.toolInstallers = import ./agent-tool-installers.nix { inherit pkgs lib; };
    local.agentEnvironment = {
      bindAddress = "10.83.0.2";
      isolation.hostShares = [ ];
      coAuthor = "Test Human <human@example.com>";
    };
    systemd.services.agent-tools.serviceConfig.RestartSec = lib.mkForce 1;
    virtualisation.vlans = [ 1 ];
    virtualisation.memorySize = 4096;
    # Mount /home after user activation, as with the microVM's data volume.
    virtualisation.fileSystems."/home" = {
      device = "tmpfs";
      fsType = "tmpfs";
    };
    local.agentGithub = {
      enable = true;
      owner = "test-upstream";
      bot = {
        login = "test-agents[bot]";
        userId = "12345";
      };
      app = {
        id = "3";
        installationId = "4";
        keyFile = "/run/test-app.pem";
      };
    };
    networking.useNetworkd = true;
    networking.useDHCP = false;
    systemd.network.networks."10-agent" = {
      matchConfig.Name = "eth1";
      address = [ "10.83.0.2/30" ];
    };
    environment.etc."test-gh-package".text = "${config.local.agentGithub.package}/bin/gh";
    environment.etc."test-global-instructions".source = ../config/AGENTS.md;
    environment.etc."test-vm-instructions".source = ../modules/agents/environment/instructions.md;
    environment.etc."test-agent-skills".source = ../config/agents/skills;
    environment.etc."test-persistent-storage.json".text = builtins.toJSON (
      map (volume: {
        inherit (volume) image serial mountPoint;
        device = persistentGuest.fileSystems.${volume.mountPoint}.device;
      }) persistentGuest.microvm.volumes
    );
    programs.git.config.url."file:///home/agent/workspace-fixture".insteadOf =
      "https://github.com/test-upstream/config.git";
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
    guest.wait_for_unit("systemd-tmpfiles-setup.service")
    guest.fail("systemctl cat agent-fork-sync.timer")
    guest.succeed("su - agent -c 'test -w /home/agent'")
    import json
    volumes = json.loads(guest.succeed("cat /etc/test-persistent-storage.json"))
    assert len({volume["serial"] for volume in volumes}) == 3
    for volume in volumes:
        assert volume["image"] == "/mnt/agents/" + volume["mountPoint"].lstrip("/") + ".img", "Persistent disk is not on the agent storage partition"
        assert volume["serial"] == "agents-" + volume["mountPoint"].lstrip("/")
        assert volume["device"] == "/dev/disk/by-id/virtio-" + volume["serial"], "Persistent disk relies on unstable device enumeration"
    guest.wait_for_unit("t3code.service")
    guest.wait_for_unit("agent-workspace.service")
    guest.succeed("su - agent -c 'test -f ~/config/README && test -w ~/config/.git/config'")
    guest.succeed("su - agent -c 'test $(git -C ~/config config remote.origin.url) = https://github.com/test-upstream/config.git'")
    guest.fail("su - agent -c 'git -C ~/config remote get-url upstream'")
    guest.succeed("su - agent -c 'git -C ~/config config test.marker retained'")
    guest.succeed("systemctl restart agent-workspace")
    guest.succeed("su - agent -c 'test $(git -C ~/config config test.marker) = retained'")
    guest.wait_until_succeeds("curl --fail --max-time 2 --output /dev/null http://10.83.0.2:3773/")
    protocol = json.loads(guest.wait_until_succeeds("curl --silent --max-time 2 http://10.83.0.2:3773/ws"))["orchestrationProtocolVersion"]
    guest.wait_until_succeeds(f"test $(curl --silent --max-time 2 --output /dev/null --write-out '%{{http_code}}' 'http://10.83.0.2:3773/ws?orchestrationProtocol={protocol}') = 401")
    t3_settings = "/home/agent/.t3/userdata/settings.json"
    guest.succeed(f"jq -e '.sidebarAutoSettleOnMerge == false' {t3_settings}")
    guest.succeed(f"su - agent -c 'jq \".sidebarAutoSettleOnMerge = true | .projectSettingsFolded = true\" {t3_settings} > ~/settings.tmp && mv ~/settings.tmp {t3_settings}'")
    guest.succeed("systemctl restart t3code")
    guest.wait_until_succeeds("curl --fail --max-time 2 --output /dev/null http://10.83.0.2:3773/")
    guest.succeed(f"jq -e '.sidebarAutoSettleOnMerge == false and .projectSettingsFolded == true' {t3_settings}")
    guest.succeed("toolpath=$(systemctl show agent-tools -p Environment --value | tr ' ' '\\n' | sed -n 's/^PATH=//p'); PATH=$toolpath awk 'BEGIN { exit 0 }'")
    guest.wait_for_unit("agent-tools.service")
    guest.succeed("su - agent -c 'codex --version && claude --version && opencode --version'")
    guest.succeed("su - agent -c 'test $(command -v codex) = ~/.local/bin/codex && test $(command -v claude) = ~/.local/bin/claude && test $(command -v opencode) = ~/.opencode/bin/opencode'")
    installations = guest.succeed("cat /home/agent/installations")
    assert installations.splitlines().count("opencode") == 2, "Failed installation was not retried"
    guest.succeed("su - agent -c 'printf \"#!${pkgs.runtimeShell}\\necho 2.1.999\\n\" > ~/.local/bin/claude'")
    guest.succeed("systemctl restart agent-tools")
    assert guest.succeed("cat /home/agent/installations") == installations, "Restart reinstalled existing tools"
    guest.succeed("su - agent -c 'test $(claude --version) = 2.1.999'")
    guest.succeed("su - agent -c 'printf \"#!${pkgs.runtimeShell}\\necho 1.19.3\\n\" > ~/.opencode/bin/opencode'")
    guest.succeed("systemctl restart agent-tools")
    assert guest.succeed("cat /home/agent/installations").splitlines().count("opencode") == 3, "OpenCode 1 was not replaced"
    guest.succeed("su - agent -c 'test $(opencode --version) = 2.1.280'")
    guest.succeed("pid=$(systemctl show t3code -p MainPID --value); t3path=$(tr '\\0' '\\n' < /proc/$pid/environ | sed -n 's/^PATH=//p'); test $(PATH=$t3path command -v claude) = /home/agent/.local/bin/claude")
    guest.succeed("pid=$(systemctl show t3code -p MainPID --value); browser=$(tr '\\0' '\\n' < /proc/$pid/environ | sed -n 's/^T3CODE_PREVIEW_BROWSER_PATH=//p'); su - agent -c \"$browser --dump-dom 'data:text/html,<p>rendered</p>'\" | grep -q rendered")
    guest.succeed("su - agent -c 'test -r ~/.codex/AGENTS.md && test -r ~/.claude/CLAUDE.md && test -r ~/.config/opencode/AGENTS.md'")
    skill_names = guest.succeed("ls /etc/test-agent-skills").splitlines()
    for directory in [".agents/skills", ".claude/skills"]:
        for name in skill_names:
            guest.succeed(f"su - agent -c 'cmp /etc/test-agent-skills/{name}/SKILL.md ~/{directory}/{name}/SKILL.md'")
        guest.succeed(f"su - agent -c 'mkdir ~/{directory}/custom && echo retained > ~/{directory}/custom/SKILL.md'")
    guest.succeed("su - agent -c 'GH_TOKEN=unused ${pkgs.gh}/bin/gh extension list | grep -q \"gh stack\"'")
    guest.succeed("su - agent -c '~/.local/share/gh/extensions/gh-stack/gh-stack --help'")
    guest.succeed("su - agent -c 'rm ~/.local/share/gh/extensions && mkdir -p ~/.local/share/gh/extensions/stale'")
    guest.succeed("systemd-tmpfiles --create")
    guest.succeed("su - agent -c 'GH_TOKEN=unused ${pkgs.gh}/bin/gh extension list | grep -q \"gh stack\"'")
    guest.succeed("systemd-tmpfiles --create")
    for directory in [".agents/skills", ".claude/skills"]:
        guest.succeed(f"su - agent -c 'test $(cat ~/{directory}/custom/SKILL.md) = retained'")
    global_instructions = guest.succeed("cat /etc/test-global-instructions")
    vm_instructions = guest.succeed("cat /etc/test-vm-instructions")
    for path in ["AGENTS.md", ".codex/AGENTS.md", ".claude/CLAUDE.md", ".config/opencode/AGENTS.md"]:
        instructions = guest.succeed(f"cat /home/agent/{path}")
        assert global_instructions in instructions, f"{path} lacks global instructions"
        assert vm_instructions in instructions, f"{path} lacks VM instructions"
    guest.succeed("jq -e '.isolation.hostShares == [] and .github.enabled == true and .github.owner == \"test-upstream\" and .configuration == \"test-upstream/config\"' /etc/agent-environment.json")
    guest.succeed("su - agent -c 'test \"$(git config --get user.name)\" = \"test-agents[bot]\"'")
    guest.succeed("su - agent -c 'test \"$(git config --get user.email)\" = \"12345+test-agents[bot]@users.noreply.github.com\"'")
    co_authored = guest.succeed(
        "su - agent -c 'cd $(mktemp -d) && git init -q && git config core.hooksPath /nonexistent"
        " && git commit -q --allow-empty -m first && git commit -q --amend --allow-empty --no-edit"
        " && git log -1 --format=%B'"
    )
    assert co_authored.count("Co-authored-by: Test Human <human@example.com>") == 1, co_authored
    guest.succeed("git config --system --get credential.useHttpPath | grep true")
    guest.fail("su - agent -c 'command -v gh-agent'")
    guest.succeed("su - agent -c 'gh --version'")
    docker = "pid=$(systemctl show t3code -p MainPID --value); export $(tr '\\0' '\\n' < /proc/$pid/environ | grep ^DOCKER_HOST=); su agent -s ${pkgs.runtimeShell} -c"
    guest.wait_until_succeeds(f"{docker} 'docker info --format {{{{.SecurityOptions}}}}' | grep -q rootless")
    guest.succeed(f"{docker} 'docker load < ${dockerTestImage}'")
    assert guest.succeed(f"{docker} 'docker run --rm agent-docker-test:latest'").strip() == "container-ran"
    guest.fail("su - agent -c 'test -w /run/docker.sock'")
    guest.fail("su - agent -c 'gh auth login'")
    guest.fail("su - agent -c 'gh pr list -R other/config'")
    guest.succeed("test $(readlink -f /run/current-system/sw/bin/gh) = $(cat /etc/test-gh-package)")
    guest.succeed("pid=$(systemctl show t3code -p MainPID --value); t3path=$(tr '\\0' '\\n' < /proc/$pid/environ | sed -n 's/^PATH=//p'); test $(PATH=$t3path command -v gh) = $(cat /etc/test-gh-package)")
    guest.fail("su - agent -c 'sudo -n true'")
  '';
}
