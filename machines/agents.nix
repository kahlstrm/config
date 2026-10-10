{ config, inputs, ... }:
{
  imports = [
    ../modules/agents/environment
    ../modules/agents/vm/guest.nix
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
    deploy = {
      enable = true;
      configuration = "agents";
      bootMode = "host";
    };
  };
  local.agentVM.diskDirectory = "/mnt/agents";
  age.secrets.agent-github-fork = {
    file = ../secrets/agent-github-fork.age;
    owner = "agent";
  };
  age.secrets.agent-github-upstream = {
    file = ../secrets/agent-github-upstream.age;
    owner = "agent";
  };
  local.agentGithub = {
    enable = true;
    forkWorkflows = true;
    sync.enable = true;
    apps.fork = {
      id = "5243770";
      installationId = "169414680";
      keyFile = config.age.secrets.agent-github-fork.path;
    };
    apps.upstream = {
      id = "5243823";
      installationId = "169415746";
      keyFile = config.age.secrets.agent-github-upstream.path;
    };
  };
}
