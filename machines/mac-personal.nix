{
  pkgs,
  currentSystemUser,
  ...
}:
{
  system.stateVersion = 5;

  # extra homebrew config for this machine specifically
  homebrew = {
    # TODO: migrate all these apps to casks
    casks = [
      "vlc"
      #"discord"
      #"zoom"
      #"google-chrome"
      "firefox"
      "sidequest"
      "winbox"
      "bambu-studio"
      "signal"
      "moonlight"
      "virtual-desktop-streamer"
      "amp-app"
      #"brave"
    ];
    masApps = {
      "telegram" = 747648890;
      "slack" = 803453959;
      "wireguard" = 1451685025;
      "utm" = 1538878817;
    };
  };

  home-manager.users.${currentSystemUser}.home.packages = with pkgs; [
    atlas
    turso-cli
    mongodb-tools
    mongosh
    beamPackages.erlang
    gleam
    azure-cli
    amp-cli
  ];
}
