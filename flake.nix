{
  description = "Nix/NixOS system configurations";

  inputs = {
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs-unstable-nixos";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs-unstable-nixos";
      inputs.darwin.follows = "darwin-unstable";
      inputs.home-manager.follows = "home-manager-unstable-nixos";
    };

    nixpkgs-unstable-darwin.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixpkgs-unstable-nixos.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-stable-nixos.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-stable-darwin.url = "github:nixos/nixpkgs/nixpkgs-25.11-darwin";
    nixpkgs-bambuddy.url = "github:NixOS/nixpkgs/b6ec51384c7827a48d6d5570f008201c25d603f4";
    bambuddy-src = {
      url = "github:kahlstrm/bambuddy/feature/process-overrides";
      flake = false;
    };

    nixpkgs-jdk24.url = "github:nixos/nixpkgs/0d05e707532d25996bd90d98a5eb467d1da9388f";

    mdatp = {
      url = "github:NitorCreations/nix-mdatp";
      inputs.nixpkgs.follows = "nixpkgs-unstable-nixos";
    };

    home-manager-unstable-darwin = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs-unstable-darwin";
    };

    home-manager-unstable-nixos = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs-unstable-nixos";
    };

    home-manager-stable-nixos = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs-stable-nixos";
    };

    home-manager-stable-darwin = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs-stable-darwin";
    };

    nix-index-database-darwin = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs-unstable-darwin";
    };

    nix-index-database-nixos = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs-unstable-nixos";
    };

    darwin-unstable = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs-unstable-darwin";
    };

    darwin-stable = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs-stable-darwin";
    };

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";

    # Secure boot, instructions https://github.com/nix-community/lanzaboote/blob/master/docs/QUICK_START.md
    lanzaboote-unstable = {
      url = "github:nix-community/lanzaboote/v1.1.0";
      inputs.nixpkgs.follows = "nixpkgs-unstable-nixos";
    };

    lanzaboote-stable = {
      url = "github:nix-community/lanzaboote/v1.1.0";
      inputs.nixpkgs.follows = "nixpkgs-stable-nixos";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    # Build a custom WSL installer
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL/main";
      inputs.nixpkgs.follows = "nixpkgs-unstable-nixos";
    };
    jovian = {
      url = "github:Jovian-Experiments/Jovian-NixOS";
      inputs.nixpkgs.follows = "nixpkgs-unstable-nixos";
    };

    nixarr-stable = {
      url = "github:rasmus-kirk/nixarr";
      inputs.nixpkgs.follows = "nixpkgs-stable-nixos";
    };

    nixarr-unstable = {
      url = "github:rasmus-kirk/nixarr";
      inputs.nixpkgs.follows = "nixpkgs-unstable-nixos";
    };

  };

  outputs =
    {
      ...
    }@inputs:
    let
      # Overlays is the list of overlays we want to apply from flake inputs.
      inputOverlays = [
        (final: _: {
          bambuddy =
            inputs.nixpkgs-bambuddy.legacyPackages.${final.stdenv.hostPlatform.system}.bambuddy.overrideAttrs
              {
                version = "1.2.5.1";
                src = inputs.bambuddy-src;
              };
        })
      ];
      formatterNixpkgs = {
        aarch64-darwin = inputs.nixpkgs-unstable-darwin;
        aarch64-linux = inputs.nixpkgs-unstable-nixos;
        x86_64-linux = inputs.nixpkgs-unstable-nixos;
      };
      personalEmail = "kalle.ahlstrom@iki.fi";
      workEmail = "kalle.ahlstrom@nitor.com";

      mkSystem = import ./lib/mksystem.nix {
        inherit
          inputOverlays
          inputs
          ;
        flakeRootPath = ./.;
        personalEmail = personalEmail;
      };
    in
    {
      formatter = builtins.mapAttrs (
        system: nixpkgs: nixpkgs.legacyPackages.${system}.nixfmt-tree
      ) formatterNixpkgs;

      checks.x86_64-linux =
        let
          pkgs = inputs.nixpkgs-unstable-nixos.legacyPackages.x86_64-linux;
        in
        {
          agent-credentials = pkgs.callPackage ./modules/agent-github/package.nix { };
          agent-network = import ./tests/agent-network.nix { inherit pkgs; };
          agent-guest = import ./tests/agent-guest.nix { inherit pkgs inputs; };
          agent-deploy = import ./tests/agent-deploy.nix { inherit pkgs; };
          steam-session = import ./tests/steam-session.nix { inherit pkgs; };
          agent-store = import ./tests/agent-store.nix { inherit pkgs; };
          agent-store-seed =
            pkgs.runCommand "agent-store-seed-tests"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                ];
              }
              ''
                bash ${./tests/agent-store-seed.sh} ${./modules/agents/vm/store-seed.sh}
                touch "$out"
              '';
        };

      darwinConfigurations.mac-personal = mkSystem "mac-personal" {
        system = "aarch64-darwin";
        user = "kalski";
        email = personalEmail;
      };

      darwinConfigurations.mac-work = mkSystem "mac-work" {
        system = "aarch64-darwin";
        user = "kahlstrm";
        email = workEmail;
        stable = false;
      };

      nixosConfigurations.pannu = mkSystem "pannu" {
        system = "x86_64-linux";
        user = "kahlstrm";
        email = personalEmail;
        stable = false;
        gui = false;
        useOutOfStoreSymlink = false;
      };

      nixosConfigurations.agents = inputs.nixpkgs-unstable-nixos.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [ ./machines/agents.nix ];
      };

      nixosConfigurations.poenttoe = mkSystem "poenttoe" {
        system = "x86_64-linux";
        user = "kahlstrm";
        email = personalEmail;
        stable = true;
        gui = false;
        useOutOfStoreSymlink = false;
        packages = {
          dev = false;
          cloud = false;
          databases = false;
        };
      };

      nixosConfigurations.zima = mkSystem "zima" {
        system = "x86_64-linux";
        user = "kahlstrm";
        email = personalEmail;
        stable = true;
        gui = false;
        useOutOfStoreSymlink = false;
        packages = {
          dev = false;
          cloud = false;
          databases = false;
        };
      };

      nixosConfigurations.frame-work = mkSystem "frame-work" {
        system = "x86_64-linux";
        user = "kahlstrm";
        email = workEmail;
        stable = false;
        secureBoot = true;
      };

      nixosConfigurations.vm-amd = mkSystem "vm-amd" {
        system = "x86_64-linux";
        user = "kahlstrm";
        email = workEmail;
        stable = false;
        useOutOfStoreSymlink = false;
      };

      nixosConfigurations.vm-utm-aarch64 = mkSystem "vm-utm-aarch64" {
        system = "aarch64-linux";
        user = "kahlstrm";
        email = workEmail;
        stable = false;
        useOutOfStoreSymlink = false;
      };

      nixosConfigurations.vm-utm-x86_64 = mkSystem "vm-utm-x86_64" {
        system = "x86_64-linux";
        user = "kahlstrm";
        email = workEmail;
        stable = false;
        useOutOfStoreSymlink = false;
      };

      nixosConfigurations.wsl = mkSystem "wsl" {
        system = "x86_64-linux";
        user = "kahlstrm";
        # TODO: should wsl-builds have parameterized email?
        email = personalEmail;
        wsl = true;
        useOutOfStoreSymlink = false;
      };

    };
}
