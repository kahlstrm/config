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
  # The roots upstream's CLI archive installs, computed from the release's own selection code.
  upstreamRuntimeExternals = pkgs.runCommand "t3code-upstream-runtime-externals" { } ''
    cd ${t3Server.src}
    ${lib.getExe pkgs.nodejs} --input-type=module -e '
      const { selectCliRuntimeExternalDependencies } = await import("./scripts/lib/cli-external-packages.ts");
      const { dependencies } = JSON.parse(await (await import("node:fs/promises")).readFile("apps/server/package.json", "utf8"));
      console.log(Object.keys(selectCliRuntimeExternalDependencies(dependencies)).sort().join("\n"));
    ' > "$out"
  '';
  # pannu's check, pointed at VM state in the test's build directory. Context is
  # dropped so the check needs only the runner's path, not a built VM image.
  vmHost = inputs.self.nixosConfigurations.pannu.config;
  vmRunner = builtins.unsafeDiscardStringContext "${vmHost.microvm.vms.agents.evaluatedConfig.config.microvm.declaredRunner
  }";
  restartPending = pkgs.writeShellScript "agent-vm-restart-pending" (
    builtins.replaceStrings [ vmHost.microvm.stateDir ] [ "vm-state" ] (
      builtins.unsafeDiscardStringContext vmHost.system.activationScripts.agent-vm-restart-pending.text
    )
  );
in
assert relative linux == relative mac;
assert toolDirectories linux == toolDirectories mac;
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
  # Installation tokens cannot read GET /user, so pull requests need the GraphQL viewer.
  grep -rq --include='*.mjs' 'viewer { databaseId login }' ${t3Server}/libexec/t3code/apps/server/dist
  # Upstream's server package is ~4.6k files; the full workspace node_modules is ~114k.
  test "$(grep -- '-t3code-' ${t3ServerClosure}/store-paths | xargs -I{} find {} | wc -l)" -lt 12000
  test -s ${upstreamRuntimeExternals}
  diff ${upstreamRuntimeExternals} ${t3Server}/libexec/t3code/runtime-externals.txt
  while read -r name; do
    test -e "${t3Server}/libexec/t3code/apps/server/node_modules/$name"
  done < ${upstreamRuntimeExternals}
  mkdir -p vm-state/agents
  test -z "$(${restartPending} 2>&1)"
  ln -s /nix/store/00000000000000000000000000000000-microvm-qemu-agents vm-state/agents/booted
  ${restartPending} 2>&1 | grep -q 'systemctl restart microvm@agents'
  ln -sfn ${vmRunner} vm-state/agents/booted
  test -z "$(${restartPending} 2>&1)"
  touch "$out"
''
