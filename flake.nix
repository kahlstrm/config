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
    # lanzaboote's tag pins a rust-overlay that still reads the deprecated stdenv.is* attributes.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs-unstable-nixos";
    };

    lanzaboote-unstable = {
      url = "github:nix-community/lanzaboote/v1.1.0";
      inputs.nixpkgs.follows = "nixpkgs-unstable-nixos";
      inputs.rust-overlay.follows = "rust-overlay";
    };

    lanzaboote-stable = {
      url = "github:nix-community/lanzaboote/v1.1.0";
      inputs.nixpkgs.follows = "nixpkgs-stable-nixos";
      inputs.rust-overlay.follows = "rust-overlay";
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
          agent-kubernetes-rbac = import ./tests/agent-kubernetes-rbac.nix { inherit pkgs; };
          agent-network = import ./tests/agent-network.nix { inherit pkgs; };
          agent-guest = import ./tests/agent-guest.nix { inherit pkgs inputs; };
          agent-storage = import ./tests/agent-storage.nix { inherit pkgs inputs; };
          agent-deploy = import ./tests/agent-deploy.nix { inherit pkgs; };
          agent-store-repair = import ./tests/agent-store-repair.nix { inherit pkgs; };
          agent-platforms = import ./tests/agent-platforms.nix { inherit pkgs inputs; };
          t3-link-cap = import ./tests/t3-link-cap.nix { inherit pkgs inputs; };
          agent-ops = import ./tests/agent-ops.nix { inherit pkgs inputs; };
          agent-ops-providers = import ./tests/agent-ops-providers.nix { inherit pkgs inputs; };
          agent-deploy-worker =
            pkgs.runCommand "agent-deploy-worker-tests" { nativeBuildInputs = [ pkgs.python3 ]; }
              ''
                mkdir -p tests modules/agents/environment
                cp ${./tests/agent-deploy-worker.py} tests/agent-deploy-worker.py
                cp ${./modules/agents/environment/deploy.py} modules/agents/environment/deploy.py
                python3 tests/agent-deploy-worker.py
                touch "$out"
              '';
          agents-md-lab =
            pkgs.runCommand "agents-md-lab-tests"
              {
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.python3
                ];
              }
              ''
                mkdir -p config tools modules/agents/environment
                cp ${./config/AGENTS.md} config/AGENTS.md
                cp ${./modules/agents/environment/instructions.md} modules/agents/environment/instructions.md
                cp -r ${./tools/agents-md-lab} tools/agents-md-lab
                python3 -m unittest discover -s tools/agents-md-lab -p "test_*.py"
                touch "$out"
              '';
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

      darwinConfigurations.agent-macos-example = inputs.darwin-unstable.lib.darwinSystem {
        specialArgs = { inherit inputs; };
        modules = [ ./tests/agent-macos-example.nix ];
      };

      nixosConfigurations.agents = inputs.nixpkgs-unstable-nixos.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [ ./machines/agents.nix ];
      };

      nixosConfigurations.ops = inputs.nixpkgs-unstable-nixos.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [ ./machines/ops.nix ];
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
