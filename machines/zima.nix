{
  currentSystemUser,
  pkgs,
  config,
  ...
}:
let
  acmeMail = "kalle.ahlstrom@iki.fi";
  acmeHost = "zima.kalski.xyz";
in
{
  imports = [
    # Include the results of the hardware scan.
    ./hardware/zima.nix
    (import ../modules/nixarr.nix {
      inherit acmeMail acmeHost;
      mediaDir = "/mnt/data/media";
      stateDir = "/mnt/data/media/.state/nixarr";
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
