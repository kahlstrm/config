# Contracts for the generic Darwin and NixOS system modules.
{ pkgs, inputs }:
let
  inherit (pkgs) lib;
  darwin =
    (inputs.darwin-unstable.lib.darwinSystem {
      system = "aarch64-darwin";
      specialArgs = {
        inherit inputs;
        currentSystemUser = "test";
        currentSystemName = "test-darwin";
      };
      modules = [ ../modules/darwin ];
    }).config;
  nixos =
    (inputs.nixpkgs-unstable-nixos.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit inputs;
        currentSystemUser = "test";
        currentSystemName = "test-nixos";
        isLinux = true;
        guiEnabled = true;
      };
      modules = [
        ../modules/nixos
        {
          system.stateVersion = "26.05";
          fileSystems."/" = {
            device = "/dev/null";
            fsType = "ext4";
          };
        }
      ];
    }).config;
  t3code = import ../pkgs/t3code.nix { inherit (pkgs) lib t3code fetchFromGitHub; };
  t3Server = pkgs.callPackage ../pkgs/t3code-server {
    t3code-unwrapped = t3code.unwrapped;
    resourceMonitor = t3code.resourceMonitor;
  };
  policyFile = nixos.environment.etc."t3code/policy.json".source;
in
assert nixos.environment.etc ? "t3code/policy.json";
assert lib.hasInfix ''"/Library/Application Support/T3Code/policy.json"''
  darwin.system.activationScripts.extraActivation.text;
assert lib.hasInfix "file:///Applications/T3%20Code%20(Beta).app/"
  darwin.system.activationScripts.postActivation.text;
pkgs.runCommand "system-configs-contracts" { nativeBuildInputs = [ pkgs.jq ]; } ''
  HOME=$TMPDIR ${t3Server}/bin/t3 policy check ${policyFile}
  jq -e '.limits.telemetry == false' ${policyFile}
  touch "$out"
''
