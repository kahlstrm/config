{
  acmeHost,
  acmeMail,
  peerPort,
  wgConf,
  mediaDir,
  stateDir,
}:
{
  resolvedModules,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    resolvedModules.nixarr
    (import ./nixarr-sso.nix {
      domain = acmeHost;
      authHost = "sonarr.${acmeHost}";
      # The apps keep enforcing API keys.
      apps = [
        "prowlarr"
        "radarr"
        "sonarr"
      ];
    })
  ];
  # give jellyfin access to GPU/render devices
  users.users.jellyfin.extraGroups = [
    "video"
    "render"
  ];

  nixarr = {
    enable = true;
    inherit mediaDir stateDir;
    vpn = {
      enable = true;
      # install this file
      wgConf = wgConf;
      # for debugging VPN
      # vpnTestService = {
      #   enable = true;
      #   port = vpnPort;
      # };
    };

    transmission = {
      enable = true;
      vpn.enable = true;
      peerPort = peerPort;
      privateTrackers.disableDhtPex = true;
    };

    jellyfin = {
      enable = true;
      # Stays on stable's Jellyfin 10.11 for now. Jellyfin 12 (unstable's `jellyfin`) migrates
      # its database one way, so its upgrade starts with state-snapshot.service on zima
      # (infra/docs/adr/2026-11-09-one-runner-per-managed-thing.md).
      expose.https = {
        enable = true;
        domainName = "jellyfin.${acmeHost}";
        acmeMail = acmeMail;
      };
      openFirewall = false; # rely on nginx only
    };

    seerr = {
      enable = true;
      # Stays on stable's Seerr 3.2 with Jellyfin 10.11. Seerr 3.5.0+ is needed to log in to
      # Jellyfin 12, and moves with it: one of its migrations remaps media statuses with no way
      # back.
      # Preserve the existing state when migrating from the jellyseerr option namespace.
      stateDir = "${stateDir}/jellyseerr";
      expose.https = {
        enable = true;
        domainName = "jellyseerr.${acmeHost}";
        acmeMail = acmeMail;
      };
      openFirewall = false; # rely on nginx only
    };

    sonarr = {
      enable = true;
      openFirewall = false;
    };
    radarr = {
      enable = true;
      openFirewall = false;
    };
    prowlarr = {
      enable = true;
      openFirewall = false;
    };
  };
  # VPN-Confinement routes IPv6 into our IPv4-only tunnel, so AAAA connects blackhole there.
  systemd.services.wg = {
    # VPN-Confinement does not reliably recreate its namespace during a live switch.
    restartIfChanged = false;
    serviceConfig.ExecStartPost = "-${pkgs.iproute2}/bin/ip -6 -n wg route del default dev wg0";
  };

  # Transmission reaches its state via /var/lib/transmission, so it otherwise has no
  # dependency on the mount and would start against an empty bind source.
  systemd.services.transmission.unitConfig.RequiresMountsFor = [ mediaDir ];

  # Reuse your existing wildcard cert for zima.kalski.xyz
  services.nginx.virtualHosts."jellyfin.${acmeHost}" = {
    enableACME = lib.mkForce false;
    useACMEHost = acmeHost;
  };
  services.nginx.virtualHosts."jellyseerr.${acmeHost}" = {
    enableACME = lib.mkForce false;
    useACMEHost = acmeHost;
  };
  services.nginx.virtualHosts."prowlarr.${acmeHost}" = {
    forceSSL = true;
    useACMEHost = acmeHost;
    locations."/" = {
      proxyPass = "http://127.0.0.1:9696";
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };
  };

  services.nginx.virtualHosts."radarr.${acmeHost}" = {
    forceSSL = true;
    useACMEHost = acmeHost;
    locations."/" = {
      proxyPass = "http://127.0.0.1:7878";
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };
  };

  services.nginx.virtualHosts."sonarr.${acmeHost}" = {
    forceSSL = true;
    useACMEHost = acmeHost;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8989";
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };
  };
}
