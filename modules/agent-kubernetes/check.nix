{ pkgs }:
let
  enrollment = pkgs.callPackage ./enroll-package.nix { inherit pkgs; };
in
pkgs.runCommand "agent-kubernetes-tests"
  {
    nativeBuildInputs = [
      enrollment
      pkgs.age
      pkgs.bash
      pkgs.jq
      pkgs.ripgrep
      pkgs.coreutils
      pkgs.git
    ];
  }
  ''
    bash ${../../tests/agent-kubernetes.sh} ${./enroll.sh}
    touch "$out"
  ''
