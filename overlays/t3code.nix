final: prev: {
  t3code = import ../pkgs/t3code.nix { inherit (prev) lib t3code fetchFromGitHub; };
}
