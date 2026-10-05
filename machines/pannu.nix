{
  pkgs,
  currentSystemUser,
  lib,
  config,
  resolvedModules,
  ...
}:

let
  sshKeys = import ../lib/ssh-keys.nix;
  bambuddyPort = 8180;
  bambuddySlicerPort = 3001;
  bambuddyFailureDetectionPort = 3333;
in
{
  imports = [
    # Include the results of the hardware scan.
    ./hardware/pannu.nix
    ../modules/remote-builder.nix
    ../modules/agents

    resolvedModules.jovian
    (import ../modules/bambuddy.nix {
      port = bambuddyPort;
      slicerPort = bambuddySlicerPort;
      failureDetectionPort = bambuddyFailureDetectionPort;
    })
    (import ../modules/steam-machine.nix { hasAmdGPU = true; })
    (import ../modules/sunshine.nix {
      hostname = "sunshine.p.kalski.xyz";
      acmeHost = "p.kalski.xyz";
    })
    (import ../modules/lact.nix {
      hasAmdGPU = true;
      adminUser = "steam-machine";
    })
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  local.remoteBuilder = {
    enable = true;
    authorizedKeys = sshKeys.builders.pannu;
  };

  local.agents = {
    enable = true;
    cores = 4;
    memoryMiB = 8192;
    proxyHost = "t3.p.kalski.xyz";
    acmeHost = "p.kalski.xyz";
    authorizedKeys = sshKeys.administrators;
    allowedServices.kubernetes-api = {
      address = "10.10.10.11";
      tcpPorts = [ 6443 ];
    };
  };

  # firmware updater
  services.fwupd.enable = true;

  users.groups.kahlstrm = { };
  users.users.${currentSystemUser} = {
    # hide user from login
    isSystemUser = true;
    isNormalUser = lib.mkForce false;
    group = "kahlstrm";
    description = "Kalle Ahlstrom";
    extraGroups = [
      "networkmanager"
      "wheel"
      "dialout"
    ];
    packages = with pkgs; [
      btop-rocm
    ];
  };

  environment.systemPackages = with pkgs; [
    rocmPackages.rocm-smi
  ];

  networking.networkmanager.enable = true; # Easiest to use and most distros use this by default.
  services.tailscale.enable = true;
  services.tailscale.extraUpFlags = [
    "--login-server=https://head.kalski.xyz"
    "--advertise-tags=tag:ark"
  ];
  services.tailscale.extraSetFlags = [
    "--accept-dns=false"
  ];
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  # Set your time zone.
  time.timeZone = "Europe/Helsinki";

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkb.options in tty.
  # };

  security.rtkit.enable = true;
  # Enable sound.
  services.pipewire = {
    enable = true;
    pulse.enable = true;
  };

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # need to wait for 6.4.0+ rocm packages
  # services.ollama = {
  #   enable = true;
  #   host = "0.0.0.0";
  #   openFirewall = true;
  #   acceleration = "rocm";
  #   environmentVariables = {
  #     OLLAMA_FLASH_ATTENTION = "1";
  #     # currently not working for Gemma3 https://github.com/ggml-org/llama.cpp/issues/12352#issuecomment-2727452955
  #     # OLLAMA_KV_CACHE_TYPE = "q8_0";
  #   };
  #   home = "/var/lib/ollama";
  # };

  # services.open-webui = {
  #   enable = true;
  #   host = "0.0.0.0";
  #   openFirewall = true;
  #   environment = {
  #     OLLAMA_API_BASE_URL = "http://127.0.0.1:11434";
  #   };
  # };

  security.acme = {
    acceptTerms = true;
    defaults.email = "kalle.ahlstrom@iki.fi";
    certs."p.kalski.xyz" = {
      inherit (config.services.nginx) group;
      domain = "p.kalski.xyz";
      dnsProvider = "cloudflare";
      environmentFile = "/var/lib/secrets/cloudflare.env";
      extraDomainNames = [ "*.p.kalski.xyz" ];
    };
  };
  services.iperf3.enable = true;
  services.iperf3.openFirewall = true;
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts = {
      "owui.p.kalski.xyz" = {
        locations."/" = {
          proxyPass = "http://127.0.0.1:8080";
          proxyWebsockets = true;
        };
        forceSSL = true;
        useACMEHost = "p.kalski.xyz";
      };

      "ollama.p.kalski.xyz" = {
        locations."/" = {
          proxyPass = "http://127.0.0.1:11434";
          proxyWebsockets = true;
        };
        forceSSL = true;
        useACMEHost = "p.kalski.xyz";
      };

      "bambuddy.p.kalski.xyz" = {
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString bambuddyPort}";
          proxyWebsockets = true;
        };
        forceSSL = true;
        useACMEHost = "p.kalski.xyz";
      };

      "p.kalski.xyz" = {
        locations."/" = {
          return = "301 https://kahlstrm.xyz";
        };
        forceSSL = true;
        useACMEHost = "p.kalski.xyz";
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  system.stateVersion = "25.05"; # Did you read the comment?
}
