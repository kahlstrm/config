{ config, inputs, ... }:
{
  imports = [
    ../modules/agents/environment
    ../modules/agent-kubernetes
    ../modules/agent-talos
    ../modules/agents/vm/guest.nix
    ../modules/agents/vm/ops-link.nix
    ../modules/amp-runner.nix
    inputs.microvm.nixosModules.microvm
    inputs.agenix.nixosModules.default
  ];
  nixpkgs = {
    config.allowUnfree = true;
    overlays = [ inputs.microvm.overlays.default ];
  };
  local.agentEnvironment = {
    authorizedKeys = (import ../lib/ssh-keys.nix).administrators;
    revision = inputs.self.rev or "dirty";
    coAuthor = "Kalle Ahlström <kalle.ahlstrom@iki.fi>";
    deploy = {
      enable = true;
      configuration = "agents";
      bootMode = "host";
    };
  };
  local.agentVM = {
    name = "agents";
    settings = import ../modules/agents/vm/settings.nix;
    passwordlessSudo = true;
    diskDirectory = "/mnt/agents";
  };
  # A temporary Amp runner beside T3, which works like an orb: passwordless root in this VM and
  # no approval prompts (infra/docs/adr/2026-11-14-temporary-compute-runners.md). It shares
  # the VM's network exceptions, and with root its threads read the VM's credentials below.
  local.ampRunner = {
    enable = true;
    hostDeploy = false;
    runnerId = "compute-pannu";
    sudo = true;
    home = "/home/amp";
    workspace = "/home/amp/workspace";
    repositories = [ "https://github.com/kahlstrm/config" ];
    extraPermissions = [
      {
        tool = "*";
        action = "allow";
      }
    ];
  };
  # pannu creates it empty; root there writes the runner's Amp access key into it, and the
  # runner starts on the VM's next boot.
  microvm.credentialFiles."amp-runner.token" = "/var/lib/microvms/agents/amp-runner.token";
  age.secrets.agent-github-app = {
    file = ../secrets/agent-github-app.age;
    owner = "agent";
  };
  local.agentGithub = {
    enable = true;
    app = {
      id = "5243823";
      installationId = "169415746";
      keyFile = config.age.secrets.agent-github-app.path;
    };
  };
}
