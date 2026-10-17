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
  toolDirectories =
    cfg:
    map (lib.removePrefix cfg.local.agentEnvironment.home) cfg.local.agentEnvironment.provisioning.tools.directories;
  deployment = mac.launchd.daemons.agent-deploy.serviceConfig;
  agents = mac.launchd.user.agents;
  gitconfig = mac.environment.etc.gitconfig.text;
  manifest =
    cfg: pkgs.writeText "agent-manifest.json" cfg.environment.etc."agent-environment.json".text;
  localVolumes =
    (inputs.self.nixosConfigurations.agents.extendModules {
      modules = [ { local.agentVM.diskDirectory = lib.mkForce "disks"; } ];
    }).config.microvm;
  nixVolume = lib.findFirst (volume: volume.mountPoint == "/nix") null localVolumes.volumes;
  t3Server = linux.local.agentEnvironment.t3Package;
  t3ServerClosure = pkgs.closureInfo { rootPaths = [ t3Server ]; };
in
assert lib.all (mountPoint: linux.fileSystems.${mountPoint}.autoResize) [
  "/home"
  "/var"
  "/nix"
];
assert lib.all (cfg: lib.versionAtLeast cfg.local.agentEnvironment.t3Package.version "0.1.0") [
  linux
  mac
];
assert relative linux == relative mac;
assert toolDirectories linux == toolDirectories mac;
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
assert
  agents.agent-tools.serviceConfig.RunAtLoad
  && agents.agent-tools.serviceConfig.KeepAlive.SuccessfulExit == false;
assert lib.hasPrefix "/Users/agent/.local/bin:/Users/agent/.opencode/bin:"
  agents.t3code.serviceConfig.EnvironmentVariables.PATH;
assert lib.hasInfix "git-credential-agent" gitconfig && lib.hasInfix "[bot]" gitconfig;
pkgs.runCommand "agent-platform-contracts" { nativeBuildInputs = [ pkgs.jq ]; } ''
  for manifest in ${manifest linux} ${manifest mac}; do
    jq -e '.deployment.enabled and .deployment.source == "merged upstream main" and .github.enabled and (.configCheckout | endswith("/agent/config"))' "$manifest"
  done
  jq -e '.deployment.bootMode == "system" and .deployment.target == "agent-macos-example"' ${manifest mac}
  jq -e '.deployment.bootMode == "host" and .isolation.mode == "VM"' ${manifest linux}
  mkdir disks
  truncate -s 1M ${nixVolume.image}
  ${localVolumes.preStart}
  test "$(stat -c %s ${nixVolume.image})" = ${toString (nixVolume.size * 1024 * 1024)}
  test "$(ls disks)" = nix.img
  test -x ${t3Server}/bin/t3
  test ! -e ${t3Server}/bin/t3code-desktop
  ! grep -- '-electron-' ${t3ServerClosure}/store-paths
  # Upstream's server package is ~4.6k files; the full workspace node_modules is ~114k.
  test "$(grep -- '-t3code-' ${t3ServerClosure}/store-paths | xargs -I{} find {} | wc -l)" -lt 12000
  touch "$out"
''
