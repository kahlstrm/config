{
  hasAmdGPU ? false,
  adminUsers ? [ ],
}:
{
  currentSystemUser,
  config,
  pkgs,
  lib,
  isStable,
  ...
}:
let
  steamSessionPackage = pkgs.callPackage ./steam-session/package.nix {
    homeDirectory = config.users.users.steam-machine.home;
  };

  compatPaths = lib.makeSearchPathOutput "steamcompattool" "" (
    with pkgs;
    [
      proton-ge-bin
    ]
  );
in
{
  environment.systemPackages = [ steamSessionPackage ];
  security.sudo.extraRules = lib.optional (adminUsers != [ ]) {
    users = adminUsers;
    runAs = "steam-machine";
    commands = [
      {
        command = "${steamSessionPackage}/bin/steam-session-control";
        options = [
          "NOPASSWD"
          "NOSETENV"
        ];
      }
    ];
  };

  users.groups."steam-machine" = { };
  users.users."steam-machine" = {
    isNormalUser = true;
    extraGroups = [
      "audio"
      "networkmanager"
      "video"
      "input"
      "games"
    ];
    group = "steam-machine";
    packages = with pkgs; [
      firefox
      mpv
    ];
  };

  # if there is disk with label 'games', mounts it
  fileSystems."/mnt/games" = {
    device = "/dev/disk/by-label/games";
    fsType = "ext4";
    options = [
      "defaults"
      "nofail"
    ];
  };

  # and makes it group writeable and changes group to 'games'
  systemd.services.setup-games-perms = {
    after = [ "mnt-games.mount" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      chgrp games /mnt/games
      chmod 775 /mnt/games
      chmod g+s /mnt/games
    '';
  };

  users.groups.games = { };
  boot.kernelModules = lib.optionals (!isStable) [ "ntsync" ];

  users.users."${currentSystemUser}".extraGroups = [ "games" ];

  jovian = {
    hardware.has.amd.gpu = hasAmdGPU;
    hardware.amd.gpu.enableBacklightControl = false;
    steam = {
      autoStart = true;
      enable = true;
      user = "steam-machine";
      # Keep Plasma disabled: DrKonqi lacks display access in Gamescope and can
      # recursively report its own crashes, exhausting the user manager's units.
      # Related upstream bug: https://bugs.debian.org/1143811
      desktopSession = "gamescope-wayland";
      environment = {
        STEAM_EXTRA_COMPAT_TOOLS_PATHS = compatPaths;
        PROTON_FSR4_UPGRADE = "1";
      };
    };
    steamos = {
      useSteamOSConfig = false;
      enableBluetoothConfig = true;
      enableDefaultCmdlineConfig = true;
      enableProductSerialAccess = true;
      enableSysctlConfig = true;
    };
  };

  programs.steam.localNetworkGameTransfers.openFirewall = true;

  # Gamescope has no desktop notification service; Sunshine can block its RTSP
  # worker on tray notifications: https://github.com/LizardByte/Sunshine/issues/4031
  services.sunshine.settings.system_tray = false;

  programs.alvr.enable = true;
  programs.alvr.openFirewall = true;
  # doesn't build with 6.15 kernel currently, and not in use
  # hardware.xone.enable = true;

}
