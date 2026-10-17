{ modulesPath, ... }:
{
  imports = [
    (if import ../../../lib/is-darwin-module.nix modulesPath then ./darwin.nix else ./nixos.nix)
    ./shared.nix
  ];
}
