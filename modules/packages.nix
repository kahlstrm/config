{
  packages ? { },
}:
let
  # Package category defaults and validation
  defaults = {
    admin = true;
    dev = true;
    cloud = true;
    databases = true;
    gui = true;
  };
  extraKeys = removeAttrs packages (builtins.attrNames defaults);
  cfg =
    assert
      extraKeys == { } || throw "unknown package categories: ${toString (builtins.attrNames extraKeys)}";
    defaults // packages;
in
{
  lib,
  pkgs,
  inputs,
  isDarwin,
  isLinux,
  currentSystem,
  pkgs-unstable,
  ...
}:

let
  wrapNixLDIfLinux =
    pkg: binName:
    if isLinux then
      (pkgs.writeShellScriptBin binName ''
        export LD_LIBRARY_PATH=$NIX_LD_LIBRARY_PATH
        exec ${pkg}/bin/${binName} "$@"
      '')
    else
      pkg;

  # Override clang on Darwin to add libiconv for Rust linking
  clangWithLibiconv =
    if isDarwin then
      pkgs.clang.override {
        extraBuildCommands = ''
          echo " -L${pkgs.libiconv}/lib" >> $out/nix-support/cc-ldflags
        '';
      }
    else
      pkgs.clang;

  # On Darwin, expose GNU date as `gdate` so BSD `date` from /usr/bin stays the default.
  # coreutils is a single multi-call binary dispatching on argv[0], so `gdate` has to be a wrapper.
  coreutilsButGdateOnDarwin =
    if isDarwin then
      pkgs.symlinkJoin {
        name = "coreutils-gdate";
        paths = [
          pkgs.coreutils
          (pkgs.writeShellScriptBin "gdate" ''
            exec -a date ${pkgs.coreutils}/bin/date "$@"
          '')
        ];
        postBuild = "rm $out/bin/date";
      }
    else
      pkgs.coreutils;

  gccWithLibiconv =
    if isDarwin then
      pkgs.gcc.override {
        extraBuildCommands = ''
          echo " -L${pkgs.libiconv}/lib" >> $out/nix-support/cc-ldflags
        '';
      }
    else
      pkgs.gcc;

  # Core packages - always installed on all systems
  corePackages = with pkgs; [
    nixos-rebuild-ng
    coreutilsButGdateOnDarwin
    gnused
    vim
    git
    gh
    htop
    btop
    fastfetch
    wget
    bat
    jq
    yq-go
    fd
    fzf
    ripgrep
    ast-grep
    tree
    tmux
    unzip
    zip
    file
    lsof
    gnupg
    hyperfine
    parallel
  ];

  # Admin packages - system administration and diagnostics
  adminPackages = with pkgs; [
    inetutils
    dig
    tcpdump
    iftop
    killall
    wireguard-tools
    openssl
    dust
    dive
    ffmpeg
    rclone
  ];

  adminLinuxPackages = with pkgs; [
    openssh
    parted
    lm_sensors
    btrfs-progs
    pciutils
  ];

  # Dev packages - programming languages, build tools
  devPackages = with pkgs; [
    inputs.agenix.packages.${currentSystem}.agenix
    pkgs-unstable.neovim
    rustup
    go
    golangci-lint
    tflint
    shellcheck
    nodejs_24
    pnpm
    # corepack
    python3
    (wrapNixLDIfLinux bun "bun")
    jdk
    uv
    cmake
    gnumake
    just
    protobuf
    nixfmt
    git-filter-repo
    wrk
    tlrc
    goreleaser
    actionlint
    yamllint
    maven
    fnox
  ];

  devCompilers = [
    clangWithLibiconv
    (lib.lowPrio gccWithLibiconv)
  ];

  devDarwinPackages = with pkgs; [
    dockutil
    cocoapods
    llvmPackages.bintools-unwrapped
    pkgs-unstable.mise
  ];

  devLinuxPackages = with pkgs; [
    bubblewrap
  ];

  # Cloud packages - cloud SDKs and Kubernetes tools
  cloudPackages = with pkgs; [
    awscli2
    google-cloud-sdk
    ssm-session-manager-plugin
    kubectl
    kustomize
    talosctl
    k9s
    fluxcd
    kubernetes-helm
    tenv
  ];

  # Database packages - database CLI clients
  databasePackages = with pkgs; [
    mariadb
    sqlite
    postgresql
  ];

  # GUI packages
  guiPackages = with pkgs; [
  ];

  guiLinuxPackages = with pkgs; [
    vscode
    brave
    bitwarden-desktop
    valgrind
    xclip
    wl-clipboard
    ghostty
  ];

  guiLinuxAmd64Packages = with pkgs; [
    spotify
    slack
  ];

  # Non-GUI linux amd64 packages
  linuxAmd64Packages = with pkgs; [
    linuxPackages.turbostat
  ];

in
{
  environment.systemPackages =
    # Core - always installed
    corePackages
    # Admin - system administration tools
    ++ lib.optionals cfg.admin adminPackages
    ++ lib.optionals (cfg.admin && isLinux) adminLinuxPackages
    # Dev - development tools
    ++ lib.optionals cfg.dev devPackages
    ++ lib.optionals cfg.dev devCompilers
    ++ lib.optionals (cfg.dev && isDarwin) devDarwinPackages
    ++ lib.optionals (cfg.dev && isLinux) devLinuxPackages
    # Cloud - cloud and k8s tools
    ++ lib.optionals cfg.cloud cloudPackages
    # Databases - database clients
    ++ lib.optionals cfg.databases databasePackages
    # GUI packages
    ++ lib.optionals cfg.gui guiPackages
    ++ lib.optionals (cfg.gui && isLinux) guiLinuxPackages
    ++ lib.optionals (cfg.gui && currentSystem == "x86_64-linux") guiLinuxAmd64Packages
    # Platform-specific (not category-gated)
    ++ lib.optionals (currentSystem == "x86_64-linux") linuxAmd64Packages;

  # workaround to allow global npm package installs
  environment.etc.npmrc.text = ''
    prefix = ''${HOME}/.npm
  '';
  environment.variables.NPM_CONFIG_GLOBALCONFIG = "/etc/npmrc";

  environment.variables.EDITOR = "vim";
  environment.variables.TENV_AUTO_INSTALL = "true";
}
