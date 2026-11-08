# A binary cache of the agent VMs' own systems. The host builds each VM's system from
# upstream main, as the guest's agent-deploy would, and serves its store to the guests
# only, so a deployment downloads instead of building in the guest's memory and disk.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentVMCache;
  vms = config.local.agentVMs;
  endpoint = import ./cache-endpoint.nix;
  harmonia = "/run/harmonia/socket";
  deployOf = name: config.microvm.vms.${name}.evaluatedConfig.config.local.agentEnvironment.deploy;
  # Environments that wait for this cache instead of building are built first.
  names = lib.sortOn (name: if (deployOf name).waitForSubstituter == null then 1 else 0) (
    lib.filter (name: (deployOf name).enable) (lib.attrNames vms)
  );
  user = "agent-cache";
  home = "/var/lib/${user}";
  warmSettings = pkgs.writeText "agent-cache-warm.json" (
    builtins.toJSON {
      systems = map (name: {
        inherit name;
        inherit (deployOf name) repository configuration;
      }) names;
      roots = "/nix/var/nix/gcroots/${user}";
      state = "${home}/built.json";
    }
  );
in
{
  options.local.agentVMCache = {
    enable = lib.mkEnableOption ''
      the agent VMs' binary cache: the host builds each VM's system from upstream main
      and serves it to the guests at their gateway addresses
    '';
    tls = lib.mkOption {
      type = lib.types.attrs;
      example = {
        useACMEHost = "p.kalski.xyz";
      };
      description = "Certificate settings of the cache's nginx virtual host, valid for `${endpoint.name}`.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.harmonia.cache = {
      enable = true;
      settings = {
        # Reached only through nginx below, never over the network directly.
        bind = "unix:${harmonia}";
        # Ahead of cache.nixos.org (40), so guests fetch what the host has over their tap.
        priority = 30;
      };
    };
    # Without signatures, the store is served only to the guests, never to the LAN or tailnet.
    services.nginx = {
      enable = true;
      virtualHosts.${endpoint.name} = cfg.tls // {
        onlySSL = true;
        listen = [
          {
            addr = "0.0.0.0";
            inherit (endpoint) port;
            ssl = true;
          }
        ];
        extraConfig = ''
          ${lib.concatMapStrings (vm: "allow ${vm.network.guestAddress};\n") (lib.attrValues vms)}deny all;
        '';
        locations."/" = {
          proxyPass = "http://unix:${harmonia}:";
          # Stream store paths to the guest instead of spooling them to disk first.
          extraConfig = "proxy_buffering off;";
        };
      };
    };

    users.users.${user} = {
      isSystemUser = true;
      group = user;
      inherit home;
    };
    users.groups.${user} = { };
    nix.settings.allowed-users = [ user ];
    systemd.tmpfiles.rules = [ "d /nix/var/nix/gcroots/${user} 0755 ${user} ${user} -" ];

    systemd.services.agent-cache-warm = {
      description = "Build the agent VMs' systems from upstream main for their guests";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [
        pkgs.git
        config.nix.package
      ];
      environment = {
        HOME = home;
        GIT_CONFIG_SYSTEM = "/dev/null";
        GIT_CONFIG_GLOBAL = "/dev/null";
        GIT_TERMINAL_PROMPT = "0";
      };
      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = user;
        StateDirectory = user;
        ExecStart = "${pkgs.python3}/bin/python3 -u ${./cache-warm.py} ${warmSettings}";
        # Evaluation runs here; the daemon's own scheduling covers the builds.
        Nice = 19;
        IOSchedulingClass = "idle";
        TimeoutStartSec = "3h";
      };
    };
    systemd.timers.agent-cache-warm = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitInactiveSec = "5min";
      };
    };
  };
}
