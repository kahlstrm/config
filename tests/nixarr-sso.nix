{ pkgs }:
let
  domain = "zima.kalski.xyz";
in
pkgs.testers.runNixOSTest {
  name = "nixarr-sso";
  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [
        (import ../modules/nixarr-sso.nix {
          inherit domain;
          protectedHosts = [ "sonarr.${domain}" ];
        })
      ];

      # Stand-in for Sonarr; it must never see an unauthenticated request.
      systemd.services.backend = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8989 --bind 127.0.0.1 --directory /etc";
      };

      services.nginx = {
        enable = true;
        virtualHosts =
          lib.recursiveUpdate
            (lib.genAttrs
              [
                "auth.${domain}"
                "sonarr.${domain}"
              ]
              (_: {
                useACMEHost = lib.mkForce null;
                sslCertificate = "${pkgs.path}/nixos/tests/common/acme/server/acme.test.cert.pem";
                sslCertificateKey = "${pkgs.path}/nixos/tests/common/acme/server/acme.test.key.pem";
              })
            )
            {
              "sonarr.${domain}" = {
                forceSSL = true;
                locations."/".proxyPass = "http://127.0.0.1:8989";
              };
            };
      };
      security.acme = {
        acceptTerms = true;
        defaults.email = "test@example.com";
      };
    };

  testScript = ''
    import urllib.parse

    def fetch(url):
        host = urllib.parse.urlsplit(url).hostname
        return machine.succeed(
            f"curl -sk -o /dev/null -w '%{{http_code}} %{{redirect_url}}' --resolve {host}:443:127.0.0.1 '{url}'"
        ).split(" ", 1)

    machine.start()
    # The VM cannot reach Pocket ID, so this also shows startup does not need the cluster.
    machine.wait_until_succeeds(
        "curl -sk -o /dev/null -w '%{http_code}' --resolve auth.${domain}:443:127.0.0.1 https://auth.${domain}/oauth2/start | grep -qx 302"
    )

    status, location = fetch("https://sonarr.${domain}/series")
    assert status == "307", status
    assert location == "https://auth.${domain}/oauth2/start?rd=https://sonarr.${domain}/series", location

    status, location = fetch(location)
    assert status == "302", status
    login = urllib.parse.urlsplit(location)
    query = urllib.parse.parse_qs(login.query)
    assert f"{login.scheme}://{login.netloc}{login.path}" == "https://id.kube.kalski.xyz/authorize", location
    assert query["client_id"] == ["zima"], query
    assert query["redirect_uri"] == ["https://auth.${domain}/oauth2/callback"], query
    assert query["code_challenge_method"] == ["S256"], query
    # allowed-group only works if Pocket ID is asked for the groups claim.
    assert "groups" in query["scope"][0].split(), query

    machine.fail("journalctl -u backend | grep -q 'GET /series'")

    # The generated cookie secret is kept, so sessions survive restarts.
    secret = machine.succeed("cat /var/lib/oauth2-proxy-secret/cookie-secret")
    machine.succeed("systemctl restart oauth2-proxy-cookie-secret")
    assert machine.succeed("cat /var/lib/oauth2-proxy-secret/cookie-secret") == secret
  '';
}
