# Runs the agents environment's T3 build with its managed settings and checks the linked-environment ceiling.
{ pkgs, inputs }:
let
  environment = inputs.self.nixosConfigurations.agents.config.local.agentEnvironment;
in
pkgs.runCommand "t3-link-cap"
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
    bash ${./t3-link-cap.sh} ${environment.t3Package}/bin/t3 "$settingsPath"
    touch "$out"
  ''
