{
  config,
  inputs,
  lib,
  ...
}:
let
  kubernetesEnrollment = ../secrets/agent-kubernetes.age;
  enrolled = builtins.pathExists kubernetesEnrollment;
in
{
  imports = [
    ../modules/agents/environment
    ../modules/agents/vm/guest.nix
    inputs.microvm.nixosModules.microvm
    inputs.agenix.nixosModules.default
    ../modules/agent-kubernetes
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
  age.secrets.agent-github-fork = {
    file = ../secrets/agent-github-fork.age;
    owner = "agent";
  };
  age.secrets.agent-github-upstream = {
    file = ../secrets/agent-github-upstream.age;
    owner = "agent";
  };
  # Enrollment activates on-demand reader tokens; no operator renewals are needed.
  age.secrets.agent-kubernetes = lib.mkIf enrolled {
    file = kubernetesEnrollment;
    owner = "agent";
    mode = "0400";
  };
  local.agentKubernetes = {
    enable = enrolled;
    bootstrapKubeconfigFile = "/run/agenix/agent-kubernetes";
  };
  systemd.services.agent-kubernetes.restartTriggers = lib.mkIf enrolled [ kubernetesEnrollment ];
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
