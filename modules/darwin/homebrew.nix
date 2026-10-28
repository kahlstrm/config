{
  inputs,
  currentSystemUser,
  ...
}:
{
  imports = [
    inputs.nix-homebrew.darwinModules.nix-homebrew
  ];

  nix-homebrew = {
    enable = true;
    user = currentSystemUser;
    # Detect and automatically migrate existing Homebrew installations
    autoMigrate = true;
    # Exported by the generated brew wrapper, so these also cover interactive use.
    # `brew analytics off` cannot persist here: HOMEBREW_REPOSITORY is a nix-managed stub.
    extraEnv = {
      HOMEBREW_NO_ANALYTICS = "1";
      HOMEBREW_NO_ENV_HINTS = "1";
    };
    # With mutableTaps disabled, taps can no longer be added imperatively with `brew tap`.
    #mutableTaps = false;
  };

  homebrew = {
    enable = true;
    casks = [
      # Development Tools
      "orbstack"
      "ghostty" # automatic update support on MacOS, hence separate
      "t3-code"

      # Communication Tools
      "chatgpt"
      "claude"

      # Utility Tools
      "shottr"
      "linearmouse"
      "hammerspoon"
    ];
    onActivation = {
      autoUpdate = false;
      upgrade = true;
    };
    taps = [ ];
    # These app IDs are from using the mas CLI app
    # mas = mac app store
    # https://github.com/mas-cli/mas
    #
    # $ nix shell nixpkgs#mas
    # $ mas search <app name>
    brews = [
    ];
    masApps = {
      "bitwarden" = 1352778147;
      "wireguard" = 1451685025;
    };
  };
}
