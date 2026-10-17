{ pkgs, inputs }:
let
  inherit (pkgs) lib;
  linux = inputs.self.nixosConfigurations.agents.config;
  mac = inputs.self.darwinConfigurations.agent-macos-example.config;
  relative =
    cfg:
    map (link: {
      path = lib.removePrefix cfg.local.agentEnvironment.home link.path;
      inherit (link) target;
    }) cfg.local.agentEnvironment.provisioning.links;
  deployment = mac.launchd.daemons.agent-deploy.serviceConfig;
  agents = mac.launchd.user.agents;
  gitconfig = mac.environment.etc.gitconfig.text;
  manifest =
    cfg: pkgs.writeText "agent-manifest.json" cfg.environment.etc."agent-environment.json".text;
in
assert relative linux == relative mac;
assert mac.local.agentEnvironment.home == "/Users/agent";
assert mac.system.primaryUser == "agent";
assert
  deployment.ProgramArguments == [
    "/run/current-system/sw/bin/agent-deploy-runner"
    "deploy"
  ];
assert
  deployment.EnvironmentVariables == {
    HOME = "/var/root";
    NIX_REMOTE = "daemon";
  };
assert agents.t3code.serviceConfig.RunAtLoad && agents.t3code.serviceConfig.KeepAlive;
assert agents.agent-workspace.serviceConfig.RunAtLoad;
assert lib.hasInfix "git-credential-agent" gitconfig && lib.hasInfix "[bot]" gitconfig;
pkgs.runCommand "agent-platform-contracts" { nativeBuildInputs = [ pkgs.jq ]; } ''
  for manifest in ${manifest linux} ${manifest mac}; do
    jq -e '.deployment.enabled and .deployment.source == "merged upstream main" and .github.enabled and (.configCheckout | endswith("/agent/config"))' "$manifest"
  done
  jq -e '.deployment.bootMode == "system" and .deployment.target == "agent-macos-example"' ${manifest mac}
  jq -e '.deployment.bootMode == "host" and .isolation.mode == "VM"' ${manifest linux}
  touch "$out"
''
