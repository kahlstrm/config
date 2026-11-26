{
  pkgs,
  currentSystemUser,
  currentSystemName,
  ...
}:
# https://daiderd.com/nix-darwin/manual/index.html
{
  imports = [
    ./darwin-dock.nix
    ./homebrew.nix
    (import ../../lib/t3-policy.nix).darwin
  ];
  networking.hostName = currentSystemName;
  system.primaryUser = currentSystemUser;
  # Allow Sudo with Touch ID.
  security.pam.services.sudo_local.touchIdAuth = true;

  system.keyboard = {
    enableKeyMapping = true;
    remapCapsLockToEscape = true;
  };

  # some of these are documented at https://macos-defaults.com/
  # https://daiderd.com/nix-darwin/manual/index.html#opt-system.defaults.CustomSystemPreferences
  # Some are defined explicitly, while other need to use either
  # CustomSystemPreferences or CustomUserPreferences
  system.defaults = {
    NSGlobalDomain = {
      AppleShowAllExtensions = true;
      ApplePressAndHoldEnabled = false;

      KeyRepeat = 2; # Values: 120, 90, 60, 30, 12, 6, 2
      InitialKeyRepeat = 25; # Values: 120, 94, 68, 35, 25, 15

      # "com.apple.mouse.tapBehavior" = 1;
      # "com.apple.sound.beep.volume" = 0.0;
      # "com.apple.sound.beep.feedback" = 0;
    };
    menuExtraClock = {
      Show24Hour = true;
      ShowDayOfWeek = true;
      ShowDate = 0;
      ShowSeconds = true;
    };
    dock = {
      autohide = true;
      show-recents = true;
      launchanim = true;
      orientation = "bottom";
    };

    finder = {
      _FXShowPosixPathInTitle = false;
    };

    trackpad = {
      Clicking = true;
      TrackpadThreeFingerDrag = true;
    };
    # NOTE: if the key has dots it needs to be quoted.
    CustomUserPreferences = {
      "com.apple.Spotlight" = {
        # Hide Spotlight icon from the menu bar
        # https://apple.stackexchange.com/questions/417604/cannot-remove-spotlight-item-from-menu-bar-with-defaults
        MenuItemHidden = 1;
        # Counterintuitively Disables spotlight search for listed applications
        EnabledPreferenceRules = [
          "com.apple.Safari"
        ];
      };
      "com.apple.ActivityMonitor".UpdatePeriod = 2;
      # Custom App Shortcuts
      # https://support.apple.com/en-us/guide/mac-help/mchlp2271/mac
      NSGlobalDomain.NSUserKeyEquivalents = {
        Zoom = "@~z";
      };
      # https://apple.stackexchange.com/questions/91679/is-there-a-way-to-set-an-application-shortcut-in-the-keyboard-preference-pane-vi
      # easiest is to first do `defaults read com.apple.symbolichotkeys > a` to capture current config, then change in the bindings in the settings app,
      # then `defaults read com.apple.symbolichotkeys > b` and then `nvim -d a b`
      "com.apple.symbolichotkeys".AppleSymbolicHotKeys = {
        "27" = {
          enabled = true;
          value = {
            parameters = [
              65535
              53
              1048576
            ];
            type = "standard";
          };
        };
        "60" = {
          enabled = false;
          value = {
            parameters = [
              32
              49
              262144
            ];
            type = "standard";
          };
        };
        "61" = {
          enabled = true;
          value = {
            parameters = [
              32
              49
              786432
            ];
            type = "standard";
          };
        };
        "65" = {
          enabled = false;
          value = {
            parameters = [
              65535
              49
              1572864
            ];
            type = "standard";
          };
        };
        "80" = {
          enabled = false;
          value = {
            parameters = [
              65535
              123
              8781824
            ];
            type = "standard";
          };
        };
        "164" = {
          enabled = false;
          value = {
            parameters = [
              65535
              65535
              0
            ];
            type = "standard";
          };
        };
        # some random "Game Overlay" binding that
        "260" = {
          enabled = 0;
          value = {
            parameters = [
              96
              50
              1048576
            ];
            type = "standard";
          };
        };
      };
    };
  };

  # Fully declarative dock using the latest from Nix Store
  local.dock.enable = true;
  local.dock.entries = [
    # installed from brew/App Store
    { path = "/Applications/Ghostty.app/"; }
    { path = "/Applications/Brave Browser.app/"; }
    { path = "/Applications/Slack.app/"; }
    { path = "/Applications/T3 Code (Beta).app/"; }
    { path = "/Applications/Bitwarden.app"; }
    {
      path = "/Users/${currentSystemUser}/Downloads/";
      section = "others";
    }
  ];
  local.dock.username = currentSystemUser;

  # The user should already exist, but we need to set this up so Nix knows
  # what our home directory is (https://github.com/LnL7/nix-darwin/issues/423).
  users.users.${currentSystemUser} = {
    home = "/Users/${currentSystemUser}";
    shell = pkgs.zsh;
  };

  environment.shells = with pkgs; [
    bashInteractive
    zsh
  ];
}
