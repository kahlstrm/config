# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## PR communication

This is a personal repository. An authorized coding task includes creating and
updating PR titles and descriptions for that work without separate text approval.
Keep them concise, factual and within the requested scope.

This overrides the global PR text approval requirement for this repository.
Other external messages, merging and deployment retain their existing
authorization requirements.

## Repository Overview

This is a multi-machine NixOS/Darwin configuration repository that manages system configurations across different platforms (macOS, NixOS, WSL, VMs). Based on Mitchell Hashimoto's nixos-config, it uses a modular flake-based architecture.

**Critical requirement**: The repository must be cloned to `~/config` for Neovim configuration and nh tool to work properly due to out-of-store symlinks.

## Infrastructure

Network, cloud, and Kubernetes configuration lives in `infra/`, with its own
flake and lockfile. Follow [infra/AGENTS.md](infra/AGENTS.md) for infrastructure
work. Run infrastructure commands from `~/config/infra`; machine commands run
from `~/config`. GitHub Actions workflows for both areas live at the root in
`.github/workflows/`.

## Development Commands

### Building and Switching
- `make switch` - Apply configuration changes (auto-detects platform and uses nh if available)
- `make build` - Build configuration without switching
- `make test` - Test configuration temporarily
- `make repl` - Load configuration in Nix REPL for debugging (requires nh)
- `NIXNAME=<config-name> make switch` - Use specific configuration by name

### Platform-specific Commands
- `nh darwin switch` - Switch on macOS (preferred method)
- `nh os switch` - Switch on NixOS (preferred method)
- `nh <darwin|os> repl` - Load configuration in Nix REPL for debugging
- `nh search` - Search nixpkgs

### Remote Deployment
- `make deploy-pannu` - Deploy to pannu machine
- `make deploy-zima` - Deploy to zima machine
- `make deploy-poenttoe` - Deploy to poenttoe cloud VM
- `make bootstrap-poenttoe` - Bootstrap new poenttoe VM (creates user, copies SSH keys)
- `make build-pannu` - Build for pannu without deploying

### Other Operations
- `make wsl` - Build WSL root tarball (requires Linux build host)
- `make fmt` - Format Nix files using nixfmt
- `make bootloader` - Install bootloader (NixOS only)

## Architecture

### Core System Builder (`lib/mksystem.nix`)
Central function that creates unified system configurations:
- Auto-detects platform (Darwin vs NixOS)
- Resolves stable/unstable nixpkgs channels via `lib/resolve-inputs.nix`
- Provides unified `specialArgs` to all modules
- Assembles module stack: nix-config → packages → OS modules → home-manager → machine config

**mkSystem parameters:**
```nix
mkSystem "machine-name" {
  system = "aarch64-darwin";  # or x86_64-linux, aarch64-linux
  user = "username";
  email = "user@example.com";
  gui = true;                 # Enable GUI packages (default: true)
  stable = false;             # Use stable channel (default: false)
  wsl = false;                # WSL-specific build (default: false)
  secureBoot = false;         # Enable lanzaboote (default: false)
  useOutOfStoreSymlink = true; # Live-edit configs like nvim (default: true)
  packages = {                # Package categories to include
    admin = true;             # System admin tools
    dev = true;               # Development tools
    cloud = true;             # Cloud SDKs, kubectl, helm
    databases = true;         # Database clients
  };
}
```

### Configuration Structure
- **flake.nix**: Entry point defining machine configurations
- **machines/**: Machine-specific configurations (one file per system)
- **modules/**: Reusable components organized by platform and function
- **lib/**: System building utilities and input resolution
- **config/**: Raw application configuration files (symlinked via home-manager)

### Module System
- **modules/shared.nix**: Cross-platform shared configuration
- **modules/packages.nix**: System packages with category-based conditionals (admin, dev, cloud, databases, gui)
- **modules/darwin/**: macOS-specific (Homebrew, system preferences, dock)
- **modules/nixos/**: NixOS-specific system configuration
- **modules/home-manager/**: User environment (dotfiles, shell, development tools)
- **modules/nix-config/**: Nix daemon settings (garbage collection, caches, distributed builds)
- **Standalone modules**: Feature modules like `gnome.nix`, `steam-machine.nix`, `headscale/` that machines can import

### Multi-Channel Support
Each configuration can use stable or unstable channels:
- Separate inputs for Darwin/NixOS stable and unstable
- `resolve-inputs.nix` selects appropriate channels based on platform and `stable` flag
- Both `pkgs-stable` and `pkgs-unstable` available in all modules

## Key Patterns

### Conditional Module Loading
Uses `lib.optionals` and `lib.optionalAttrs` for:
- Platform-specific modules (`isDarwin`, `isLinux`)
- Feature flags (`guiEnabled`, WSL-specific, steam machine)
- Architecture-specific packages

### Out-of-Store Symlinks
Development configs (especially Neovim) use `useOutOfStoreSymlink` for live editing without system rebuilds.

### VM Tests
After each state change in a NixOS test script (boot, service restart, reload), wait for the changed service to answer with one `wait_until_succeeds`, then assert with single-shot `succeed`/`fail`. Negative checks stay single-shot, and run after a positive readiness check so they cannot pass because the network is still down.

### Machine Configuration Template
New machines need:
1. Entry in `flake.nix` outputs with `mkSystem "machine-name" { ... }`
2. File at `machines/machine-name.nix` 
3. For NixOS: hardware config at `machines/hardware/machine-name.nix`

### Special Arguments Available in All Modules
- `currentSystemUser`, `currentSystemEmail`: User details
- `isDarwin`, `isLinux`: Platform detection
- `guiEnabled`: GUI vs headless flag
- `pkgs-stable`, `pkgs-unstable`: Channel access
- `flakeRoot`: Path for symlink creation
- `resolvedModules`: Pre-resolved external modules (`nixarr`, `jovian`, `mdatp`, `nixos-hardware`)
