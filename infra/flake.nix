{
  description = "Development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        chrImage = pkgs.callPackage ./experiments/chr/image.nix { };
        chrPackages = with pkgs; [
          python3
          qemu
          openssh
          curl
          just
        ];
      in
      {
        packages = {
          chr-image = chrImage;
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          iperf3-image = import ./experiments/network-diagnostics/iperf3-image.nix { inherit pkgs; };
        };
        devShells.default = import ./shell.nix { inherit pkgs; };
        devShells.chr = pkgs.mkShellNoCC {
          CHR_IMAGE = chrImage;
          packages = chrPackages;
        };
        devShells.chr-dns = pkgs.mkShellNoCC {
          CHR_IMAGE = chrImage;
          packages = chrPackages ++ [ pkgs.dig ];
        };
        devShells.chr-bootstrap = pkgs.mkShellNoCC {
          CHR_IMAGE = chrImage;
          packages = chrPackages ++ [
            pkgs.opentofu
            pkgs.jq
            pkgs.dig
          ];
        };

      }
    );
}
