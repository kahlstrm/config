{ pkgs }:
let
  package = pkgs.callPackage ./package.nix { inherit pkgs; };
  enrollment = pkgs.callPackage ./enroll-package.nix { inherit pkgs; };
in
pkgs.runCommand "agent-kubernetes-tests"
  {
    nativeBuildInputs = [
      package
      enrollment
      pkgs.bash
      pkgs.jq
      pkgs.ripgrep
      pkgs.coreutils
      pkgs.git
    ];
  }
  ''
    bash ${../../tests/agent-kubernetes.sh} ${./credential.sh} ${./setup.sh} ${./enroll.sh} ${package}
    touch "$out"
  ''
