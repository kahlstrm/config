{
  currentSystemUser,
  pkgs,
  config,
  ...
}:
let
  acmeMail = "kalle.ahlstrom@iki.fi";
  acmeHost = "zima.kalski.xyz";
  stateDir = "/mnt/data/media/.state/nixarr";
in
{
  imports = [
    # Include the results of the hardware scan.
    ./hardware/zima.nix
    ../modules/ops-deploy.nix
    ../modules/amp-runner.nix
    ../modules/state-snapshot.nix
    (import ../modules/nixarr.nix {
      inherit acmeMail acmeHost stateDir;
      mediaDir = "/mnt/data/media";
      wgConf = "/data/.secret/wg.conf";
      peerPort = 3666;
    })
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Headless: an emergency shell nobody can reach needs a physical power cycle, so boot on
  # instead and leave the failure visible over ssh.
  systemd.enableEmergencyMode = false;

  services.fwupd.enable = true;

  # Enable networking
  networking.networkmanager.enable = true;
  services.tailscale.enable = true;
  services.tailscale.extraUpFlags = [
    "--login-server=https://head.kalski.xyz"
    "--advertise-tags=tag:https"
  ];
  services.tailscale.extraSetFlags = [
    "--accept-dns=false"
  ];
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  # OpenSSH for remote administration
  services.openssh.enable = true;
  local.opsDeploy.enable = true;
  # Amp threads deploy and debug zima through this runner
  # (infra/docs/adr/2026-11-09-one-runner-per-managed-thing.md). Its access key is zima's own;
  # a maintainer installs it once, as root on zima, and pastes the key followed by Ctrl-D:
  #   install -d -m 0700 /etc/credstore.encrypted && systemd-creds encrypt --name=amp-runner.token - /etc/credstore.encrypted/amp-runner.token
  # The runner starts at the next deploy, or with `systemctl start amp-runner` once deployed.
  # Before the first deploy, follow "Bootstrapping zima's runner" in that ADR.
  local.ampRunner = {
    enable = true;
    readOnlyUnits = [ "jellyfin-plugins.service" ];
  };
  # Jellyfin's and Seerr's state before a one-way migration, such as Jellyfin's database
  # upgrades. Both directories are their own subvolumes, converted as modules/state-snapshot.nix
  # describes, so snapshots never pin deleted media.
  local.stateSnapshot = {
    enable = true;
    name = "jellyfin";
    directory = "/mnt/data/.snapshots";
    subvolumes = [
      "${stateDir}/jellyfin"
      "${stateDir}/jellyseerr"
    ];
    services = [
      "jellyfin.service"
      "seerr.service"
    ];
  };
  # Lists Jellyfin's installed plugins into the journal, as amp cannot read Jellyfin's state.
  systemd.services.jellyfin-plugins = {
    description = "List Jellyfin's plugins";
    serviceConfig = {
      Type = "oneshot";
      User = config.services.jellyfin.user;
      ExecStart = "${pkgs.coreutils}/bin/ls -la --time-style=long-iso ${config.services.jellyfin.dataDir}/plugins";
      ProtectSystem = "strict";
      PrivateNetwork = true;
    };
  };

  # Set your time zone.
  time.timeZone = "UTC";

  users.users.${currentSystemUser} = {
    isNormalUser = true;
    description = "Kalle Ahlstrom";
    extraGroups = [
      "docker"
      "networkmanager"
      "wheel"
    ];
  };

  environment.systemPackages = with pkgs; [ btrfs-progs ];

  security.acme = {
    acceptTerms = true;
    defaults.email = acmeMail;
    certs."zima.kalski.xyz" = {
      inherit (config.services.nginx) group;
      domain = acmeHost;
      dnsProvider = "cloudflare";
      environmentFile = "/data/.secret/cloudflare.env";
      extraDomainNames = [ "*.${acmeHost}" ];
    };
    certs."jet.kalski.xyz" = {
      domain = "jet.kalski.xyz";
      dnsProvider = "cloudflare";
      environmentFile = "/data/.secret/cloudflare.env";
      # Need to setup host root SSH-key and add public key to jetKVM for this to work
      # Settings -> Advanced
      # Developer Mode on
      # Then add key to "SSH Public key" list
      postRun = ''
        ${pkgs.openssh}/bin/ssh root@jet.kalski.xyz "mkdir -p /userdata/jetkvm/tls"
        cat fullchain.pem | ${pkgs.openssh}/bin/ssh root@jet.kalski.xyz "cat > /userdata/jetkvm/tls/user-defined.crt"
        cat key.pem | ${pkgs.openssh}/bin/ssh root@jet.kalski.xyz "cat > /userdata/jetkvm/tls/user-defined.key"
        ${pkgs.openssh}/bin/ssh root@jet.kalski.xyz "sed -i 's/\"tls_mode\": \"\"/\"tls_mode\": \"custom\"/' /userdata/kvm_config.json"
        ${pkgs.openssh}/bin/ssh root@jet.kalski.xyz "sh -c 'sleep 1; sync; reboot' </dev/null >/dev/null 2>&1 &"
      '';
    };
  };

  system.stateVersion = "25.05"; # Did you read the comment?
}
