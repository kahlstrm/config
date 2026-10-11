{ pkgs }:
pkgs.writeShellApplication {
  name = "agent-kubernetes-enroll";
  runtimeInputs = [
    (pkgs.callPackage ./kubectl.nix { })
    pkgs.jq
    pkgs.age
    pkgs.nix
    pkgs.git
    pkgs.coreutils
  ];
  text = builtins.readFile ./enroll.sh;
}
