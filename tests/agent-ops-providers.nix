# Runs the ops environment's T3 build with its managed settings and checks that only Claude is offered.
{ pkgs, inputs }:
let
  environment = inputs.self.nixosConfigurations.ops.config.local.agentEnvironment;
in
pkgs.runCommand "agent-ops-providers"
  {
    nativeBuildInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.git
    ];
    settings = builtins.toJSON environment.t3Settings;
    passAsFile = [ "settings" ];
  }
  ''
    bash ${./agent-ops-providers.sh} ${environment.t3Package}/bin/t3 "$settingsPath"
    touch "$out"
  ''
