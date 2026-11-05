{
  pkgs,
  lib,
  inputs,
  currentSystemUser,
  ...
}:
let
  jdk24 = inputs.nixpkgs-jdk24.legacyPackages.${pkgs.stdenv.hostPlatform.system}.zulu24;
  toolchainJdks = [
    pkgs.jdk17
    pkgs.jdk21
    jdk24
  ];
in
{
  # Set in Sept 2024 as part of the macOS Sequoia release.
  system.stateVersion = 5;

  # extra homebrew config for this machine specifically
  homebrew = {
    # TODO: migrate all these apps to casks
    casks = [
      "session-manager-plugin"
      #"discord"
      #"zoom"
      #"google-chrome"
      #"firefox"
      #"brave"
    ];
    brews = [
    ];
    masApps = {
      "telegram" = 747648890;
      "utm" = 1538878817;
    };
  };

  environment.systemPackages = with pkgs; [
    swagger-codegen3
    xcodes
    android-tools
  ];

  home-manager.users.${currentSystemUser} = {
    home.file.".gradle/gradle.properties".text = ''
      org.gradle.java.installations.auto-detect=true
      org.gradle.java.installations.paths=${lib.concatMapStringsSep "," toString toolchainJdks}
      org.gradle.jvmargs=-Xmx4g
    '';
  };
}
