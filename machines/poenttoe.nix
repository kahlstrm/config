{
  currentSystemUser,
  config,
  ...
}:
{
  imports = [
    ./hardware/poenttoe.nix
    ../modules/headscale
    ../modules/ops-deploy.nix
    ../modules/backup.nix
  ];
  # Headscale's database and keys (modules/backup.nix). poenttoe cannot reach zima, so it backs
  # up off-site only, once its credentials are installed, and zima copies the snapshots down.
  local.backup = {
    enable = true;
    toZima = false;
    paths = [
      "/var/lib/headscale"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_rsa_key"
    ];
  };

  networking.hostName = "poenttoe";

  # OpenSSH for remote administration
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "no";
    settings.PasswordAuthentication = true;
  };
  local.opsDeploy.enable = true;
  services.iperf3.enable = true;
  services.iperf3.openFirewall = true;

  networking.firewall.allowedTCPPorts = [ 5202 ];
  systemd.services.iperf3-upload = {
    description = "iperf3 upload test endpoint";
    inherit (config.systemd.services.iperf3) after wantedBy;
    serviceConfig = config.systemd.services.iperf3.serviceConfig // {
      ExecStart = "${config.services.iperf3.package}/bin/iperf3 --server --port 5202";
    };
  };

  # Match infected config defaults
  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;

  # ZeroTier
  services.zerotierone.enable = true;

  # Set your time zone.
  time.timeZone = "UTC";

  users.users.${currentSystemUser} = {
    isNormalUser = true;
    description = "Kalle Ahlstrom";
    extraGroups = [
      "wheel"
    ];
  };

  system.stateVersion = "23.11";
}
