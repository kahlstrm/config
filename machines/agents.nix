{ config, inputs, ... }:
{
  imports = [
    ../modules/agents/environment
    ../modules/agent-kubernetes
    ../modules/agent-talos
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
    coAuthor = "Kalle Ahlström <kalle.ahlstrom@iki.fi>";
    deploy = {
      enable = true;
      configuration = "agents";
      bootMode = "host";
    };
  };
  local.agentVM.diskDirectory = "/mnt/agents";
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
