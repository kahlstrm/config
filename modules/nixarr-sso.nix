# Pocket ID login in front of nginx vhosts, served from auth.<domain>.
# The public PKCE client is declared in infra/local-kubernetes/apps/pocket-id-sync/identity.json,
# which also limits it to the admins group. The cookie secret is generated on first start.
# auth.<domain> needs a Headscale internal DNS record like the other vhosts (infra/README.md).
{
  domain,
  protectedHosts,
  issuer ? "https://id.kube.kalski.xyz",
}:
{ lib, pkgs, ... }:
let
  authHost = "auth.${domain}";
  cookieSecret = "/var/lib/oauth2-proxy-secret/cookie-secret";
in
{
  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    clientID = "zima";
    approvalPrompt = "auto";
    oidcIssuerUrl = issuer;
    # Pinned endpoints let oauth2-proxy start while the cluster is down; only logins need it.
    loginURL = "${issuer}/authorize";
    redeemURL = "${issuer}/api/oidc/token";
    redirectURL = "https://${authHost}/oauth2/callback";
    cookie.secretFile = cookieSecret;
    cookie.domain = ".${domain}";
    email.domains = [ "*" ];
    reverseProxy = true;
    trustedProxyIP = [ "127.0.0.1" ];
    setXauthrequest = true;
    extraConfig = {
      allowed-group = "admins";
      # Required by oauth2-proxy but ignored for the public client; not a secret.
      client-secret = "public";
      code-challenge-method = "S256";
      oidc-jwks-url = "${issuer}/.well-known/jwks.json";
      skip-oidc-discovery = true;
      whitelist-domain = ".${domain}";
    };
    nginx = {
      domain = authHost;
      virtualHosts = lib.genAttrs protectedHosts (_: { });
    };
  };

  systemd.services.oauth2-proxy-cookie-secret = {
    requiredBy = [ "oauth2-proxy.service" ];
    before = [ "oauth2-proxy.service" ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "oauth2-proxy-secret";
      StateDirectoryMode = "0700";
      UMask = "0077";
    };
    script = ''
      if [ ! -s ${cookieSecret} ]; then
        ${lib.getExe pkgs.openssl} rand -hex 16 > ${cookieSecret}.tmp
        mv ${cookieSecret}.tmp ${cookieSecret}
      fi
    '';
  };

  services.nginx.virtualHosts.${authHost} = {
    forceSSL = true;
    useACMEHost = domain;
  };
}
