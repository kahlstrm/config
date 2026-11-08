# Pocket ID login in front of the Servarr apps' nginx vhosts (<app>.<domain>). Logins start
# and return on authHost, an existing protected vhost, so one callback URL serves them all
# and no extra DNS is needed. The apps drop their own login and trust every request.
# The public PKCE client is declared in infra/local-kubernetes/apps/pocket-id-sync/identity.json,
# which also limits it to the admins group. The cookie secret is generated on first start.
{
  domain,
  authHost,
  apps,
  issuer ? "https://id.kube.kalski.xyz",
}:
{ lib, pkgs, ... }:
let
  cookieSecret = "/var/lib/oauth2-proxy-secret/cookie-secret";
in
{
  # Without their own login, the apps must be reachable only through nginx.
  services =
    lib.genAttrs apps (_: {
      settings.auth.method = "External";
      settings.server.bindaddress = "127.0.0.1";
    })
    // {
      oauth2-proxy = {
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
          virtualHosts = lib.genAttrs (map (app: "${app}.${domain}") apps) (_: { });
        };
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
}
