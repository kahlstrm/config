{
  pkgs,
  currentSystemUser,
  currentSystemName,
  isLinux,
  guiEnabled,
  lib,
  options,
  ...
}:

{
  # Add ~/.local/bin to PATH
  environment.localBinInPath = true;
  programs.firefox.enable = isLinux && guiEnabled;
  programs.npm.enable = true;
  # Text-to-speech that graphical sessions enable by default; nothing here uses it.
  services.speechd.enable = false;

  networking.hostName = currentSystemName;

  services.journald =
    if options.services.journald ? settings then
      { settings.Journal.SystemMaxUse = lib.mkDefault "512M"; }
    else
      {
        extraConfig = lib.mkDefault ''
          SystemMaxUse=512M
        '';
      };

  users.users.${currentSystemUser} = {
    isNormalUser = true;
    home = "/home/${currentSystemUser}";
    extraGroups = [
      "docker"
      "wheel"
    ];
    shell = pkgs.zsh;
  };
  environment.shells = with pkgs; [
    bashInteractive
    zsh
  ];

  # Enables native Wayland on Chromium/Electron based applications
  # environment.sessionVariables.NIXOS_OZONE_WL = "1";

  xdg.terminal-exec = lib.optionalAttrs guiEnabled {
    enable = true;
    settings = {
      default = [
        "com.mitchellh.ghostty.desktop"
      ];
    };
  };

  programs.zsh.enable = true;
  programs.nix-ld.enable = true;
  # Virtualization settings
  virtualisation.docker = {
    enable = true;
    # The current stable nixpkgs defaults to Docker 28, which it also marks as insecure.
    package = pkgs.docker_29;
  };

  i18n = {
    defaultLocale = "en_US.UTF-8";
  };
}
