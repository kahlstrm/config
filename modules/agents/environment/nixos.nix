{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentEnvironment;
  sshHostKey = "/var/lib/ssh/ssh_host_ed25519_key";
  # Chrome for Testing names its archive directory after the platform.
  previewBrowser =
    let
      platform = if pkgs.stdenv.hostPlatform.isAarch64 then "linux-arm64" else "linux64";
    in
    "${pkgs.playwright-driver.components.chromium-headless-shell}/chrome-headless-shell-${platform}/chrome-headless-shell";
in
{
  imports = [
    ./tooling.nix
    ./deploy.nix
    ./store-repair.nix
  ];
  config = {
    system.stateVersion = lib.mkDefault "26.05";
    users.mutableUsers = false;
    # The only login is the unprivileged agent's SSH key; root stays locked.
    users.allowNoPasswordLogin = true;
    users.users.${cfg.user} = {
      isNormalUser = true;
      # Fixed so DOCKER_HOST can name the rootless daemon's socket.
      uid = 1000;
      home = "/home/${cfg.user}";
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
      # Starts the rootless Docker daemon at boot.
      linger = true;
    };
    virtualisation.docker.rootless = {
      enable = true;
      setSocketVariable = true;
    };
    services.openssh = {
      enable = true;
      hostKeys = [
        {
          path = sshHostKey;
          type = "ed25519";
        }
      ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        AllowUsers = [ cfg.user ];
      };
    };
    networking.firewall.allowedTCPPorts = [
      22
      cfg.t3Port
    ];
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [ "root" ];
      auto-optimise-store = false;
    };
    nix.gc = {
      automatic = true;
      options = "--delete-older-than 14d";
    };
    programs.nix-ld.enable = true;
    programs.git = {
      enable = true;
      config = cfg.provisioning.gitConfig;
    };
    systemd.tmpfiles.rules =
      # The persistent /home volume mounts after user activation creates homes.
      map (path: "d ${path} 0700 ${cfg.user} users -") cfg.provisioning.directories
      ++ map (link: "L+ ${link.path} - ${cfg.user} users - ${link.target}") cfg.provisioning.links
      ++ [ "d ${builtins.dirOf sshHostKey} 0700 root root -" ];
    age.identityPaths = [ sshHostKey ];
    systemd.services.agent-workspace = {
      description = "Initialize the agent's environment configuration checkout";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [
        pkgs.git
        pkgs.coreutils
      ];
      environment.HOME = cfg.home;
      serviceConfig = {
        User = cfg.user;
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 60;
        UMask = "0077";
      };
      script = cfg.provisioning.workspaceScript;
    };
    systemd.services.t3code = {
      description = "T3 coding agent server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = config.environment.systemPackages;
      environment = {
        HOME = cfg.home;
        T3CODE_PREVIEW_BROWSER_PATH = previewBrowser;
        DOCKER_HOST = "unix:///run/user/${toString config.users.users.${cfg.user}.uid}/docker.sock";
      };
      serviceConfig = {
        User = cfg.user;
        WorkingDirectory = cfg.home;
        ExecStart = "${cfg.t3Package}/bin/t3 serve --host ${cfg.bindAddress} --port ${toString cfg.t3Port}";
        Restart = "on-failure";
        RestartSec = 5;
        UMask = "0077";
        NoNewPrivileges = true;
        TasksMax = 2048;
      };
    };
  };
}
