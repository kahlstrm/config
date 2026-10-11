{ pkgs }:
let
  kubectl = pkgs.callPackage ./kubectl.nix { };
  application =
    name: source:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        kubectl
        pkgs.jq
        pkgs.coreutils
      ];
      text = builtins.readFile source;
    };
in
pkgs.symlinkJoin {
  name = "agent-kubernetes";
  passthru = { inherit kubectl; };
  paths = [
    (application "agent-kube-credential" ./credential.sh)
    (application "agent-kube-setup" ./setup.sh)
  ];
}
