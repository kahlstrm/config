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
    ../modules/ops-deploy.nix
    ../modules/amp-runner.nix
    ../modules/infra-apply
    (import ../modules/aio-repro-ramdisk.nix { sizeGiB = 16; })

    resolvedModules.jovian
    (import ../modules/bambuddy.nix {
      port = bambuddyPort;
      slicerPort = bambuddySlicerPort;
      failureDetectionPort = bambuddyFailureDetectionPort;
    })
    (import ../modules/steam-machine.nix {
      hasAmdGPU = true;
      adminUsers = [ currentSystemUser ];
    })
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
  # The IOMMU lets a device be passed through to a VM, such as the GPU to the agents VM. Passthrough mode keeps
  # the devices the host itself uses out of its translation
  boot.kernelParams = [
    "amd_iommu=on"
    "iommu=pt"
  ];
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  local.remoteBuilder = {
    enable = true;
    authorizedKeys = sshKeys.builders.pannu;
  };

  local.agentVMs =
    let
      agents = import ../modules/agents/vm/settings.nix;
      ops = import ../modules/agents/vm/ops-settings.nix;
      network = settings: {
        inherit (settings.network)
          interface
          hostAddress
          guestAddress
          prefixLength
          ;
      };
    in
    {
      agents = {
        cores = 8;
        memoryMiB = 32768;
        # The first VM's units predate multiple VMs; renaming them would restart it on switch.
        unitPrefix = "agent";
        proxyHost = "t3.p.kalski.xyz";
        acmeHost = "p.kalski.xyz";
        network = network agents;
        allowedServices = agents.allowedServices // {
          # The T3 link to ops. Host-only for now, so the agents boot image stays unchanged.
          ops-t3 = {
            address = ops.network.guestAddress;
            tcpPorts = [ ops.t3Port ];
          };
        };
      };
      ops = {
        cores = 2;
        memoryMiB = 4096;
        # The wildcard *.p.kalski.xyz certificate and DNS record cover this name.
        proxyHost = "t3-ops.p.kalski.xyz";
        acmeHost = "p.kalski.xyz";
        network = network ops;
        inherit (ops) allowedServices;
        allowedClients.agents.tcpPorts = [ ops.t3Port ];
        # A pannu deploy boots ops' new image at once, ending ops' running sessions. Its image
        # embeds the commit, so every deploy of a new main restarts it.
        restartOnSwitch = true;
      };
    };
  # pannu builds both VMs' systems from main and serves them; ops is too small to build T3 Code.
  local.agentVMCache = {
    enable = true;
    tls.useACMEHost = "p.kalski.xyz";
  };
  # Builds, including that warm-up, yield to games and the agent VMs.
  nix.daemonCPUSchedPolicy = "idle";
  nix.daemonIOSchedClass = "idle";
  # Runner and cache builds can fill the disk between weekly collections; collect dead paths
  # during a build once free space drops below min-free.
  nix.settings = {
    min-free = 20 * 1024 * 1024 * 1024;
    max-free = 60 * 1024 * 1024 * 1024;
  };
  # Ops deploys merged main here and boots the VM images that stages; from its tap address
  # no other account may log in.
  local.opsDeploy = {
    enable = true;
    restartableVMs = lib.attrNames config.local.agentVMs;
    exclusiveFrom = [ (import ../modules/agents/vm/ops-settings.nix).network.guestAddress ];
  };
  # Amp threads deploy pannu from merged main and debug it through this runner, beside ops'
  # path (infra/docs/adr/2026-11-09-amp-runners-on-hosts.md, step M2). Its access key is
  # installed by hand into /etc/credstore.encrypted/amp-runner.token.
  local.ampRunner.enable = true;
  # Plans and applies of infra/ layers from merged main, which the runner starts; see the module.
  # A layer's key ID is set once its certificate is uploaded.
  local.infraApply.layers.local-networking.serviceAccount =
    "infra-local-networking@infra-464520.iam.gserviceaccount.com";
  # The runner may not stop or restart ops, nor what ops requires or is part of through its
  # template; ops restarts only when a deploy changes its image. The agents VM's firewall
  # stays up too.
  local.ampRunner.protectedUnits = [
    "microvm@ops.service"
    "microvm-tap-interfaces@ops.service"
    "microvm-macvtap-interfaces@ops.service"
    "microvm-pci-devices@ops.service"
    "microvm-virtiofsd@ops.service"
    "microvm-set-booted@ops.service"
    "agent-ops-network.service"
    "agent-network.service"
    "agent-storage.service"
  ];
  # Break-glass read-only cluster access while the klusse runner is down
  # (infra/docs/adr/2026-11-09-one-runner-per-managed-thing.md). The token is
  # encrypted to pannu's host key alone, so nothing else decrypts it; to rotate, write it anew.
  # Enroll from the repository root once Flux has applied the break-glass-reader Secret:
  #   token=$(kubectl --context=admin@klusse --namespace=agent-debug get secret break-glass-reader-token --output=go-template='{{.data.token | base64decode}}') &&
  #     nix run nixpkgs#age -- --encrypt --recipient "$(nix eval --raw --file lib/ssh-keys.nix 'hosts."p.kalski.xyz"')" --output secrets/amp-runner-kubernetes-token.age <<< "$token"
  # Commit the file and deploy pannu. Delete the file and deploy to revoke it from pannu, and
  # recreate the Secret to invalidate the token itself.
  age.secrets = lib.optionalAttrs (builtins.pathExists ../secrets/amp-runner-kubernetes-token.age) {
    amp-runner-kubernetes-token = {
      file = ../secrets/amp-runner-kubernetes-token.age;
      owner = "amp";
      group = "amp";
      mode = "0400";
    };
  };
  local.ampRunner.kubernetesTokenFile = config.age.secrets.amp-runner-kubernetes-token.path or null;
  # Both VMs keep their disks on the agents partition, ops in its own directory.
  # The 341 GiB partition had 99 GiB free with agents' 240 GiB and ops' 18 GiB reserved
  # (2026-11-03), so fully allocating ops' 30 GiB still leaves well over 50 GiB free.
  local.agentVMDiskBudgetMiB = 272 * 1024;
  systemd.services."microvm@agents".unitConfig.RequiresMountsFor = [ "/mnt/agents" ];
  systemd.services."microvm@agents".requires = [ "agent-storage.service" ];
  systemd.services."microvm@ops".unitConfig.RequiresMountsFor = [ "/mnt/agents" ];
  systemd.services."microvm@ops".requires = [ "agent-storage.service" ];
  systemd.services.agent-storage = {
    requires = [ "mnt-agents.mount" ];
    after = [ "mnt-agents.mount" ];
    before = [
      "microvm@agents.service"
      "microvm@ops.service"
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.coreutils}/bin/install -d -m 0750 -o microvm -g kvm /mnt/agents /mnt/agents/ops
    '';
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
  # Keep resolvconf when networkd is enabled for the agent VM tap.
  services.resolved.enable = false;
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
  time.timeZone = "UTC";
  # The Steam session's player is in Helsinki
  jovian.steam.environment.TZ = "Europe/Helsinki";

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
  # The cluster's Prometheus scrapes this from a Kuberack node's address to watch
  # contention between games and the agent VMs (infra ADR on agent VM placement).
  services.prometheus.exporters.node.enable = true;
  # IPv4 only: the module's firewallFilter also goes to ip6tables.
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -s 10.10.10.0/24 -p tcp --dport 9100 -j nixos-fw-accept
  '';
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

      # Bambuddy alone, for the ops VM only, on a port its network exception names.
      "bambuddy-ops" =
        let
          endpoint = import ../modules/agents/vm/bambuddy-endpoint.nix;
          ops = import ../modules/agents/vm/ops-settings.nix;
        in
        {
          serverName = endpoint.name;
          onlySSL = true;
          useACMEHost = "p.kalski.xyz";
          listen = [
            {
              # The tap's address exists only while ops runs, so nginx could not bind it at
              # boot; the firewall opens the port on ops' tap alone, like the binary cache's.
              addr = "0.0.0.0";
              inherit (endpoint) port;
              ssl = true;
            }
          ];
          extraConfig = ''
            allow ${ops.network.guestAddress};
            deny all;
          '';
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString bambuddyPort}";
            # Print files (3MF with plates and thumbnails) often exceed nginx's 10 MiB default.
            extraConfig = "client_max_body_size 512m;";
          };
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
