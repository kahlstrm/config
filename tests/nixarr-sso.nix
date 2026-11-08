{ pkgs }:
let
  domain = "zima.kalski.xyz";
  authHost = "sonarr.${domain}";
in
pkgs.testers.runNixOSTest {
  name = "nixarr-sso";
  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [
        (import ../modules/nixarr-sso.nix {
          inherit domain authHost;
          apps = [
            "radarr"
            "sonarr"
          ];
        })
      ];

      # Real Sonarr, which has no login of its own behind the proxy.
      services.sonarr.enable = true;
      # Stand-in for Radarr; it must never see an unauthenticated request.
      systemd.services.backend = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 7878 --bind 127.0.0.1 --directory /etc";
      };

      services.nginx = {
        enable = true;
        virtualHosts =
          lib.recursiveUpdate
            (lib.genAttrs
              [
                "radarr.${domain}"
                "sonarr.${domain}"
              ]
              (_: {
                useACMEHost = lib.mkForce null;
                sslCertificate = "${pkgs.path}/nixos/tests/common/acme/server/acme.test.cert.pem";
                sslCertificateKey = "${pkgs.path}/nixos/tests/common/acme/server/acme.test.key.pem";
              })
            )
            {
              "radarr.${domain}" = {
                forceSSL = true;
                locations."/".proxyPass = "http://127.0.0.1:7878";
              };
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
        "curl -sk -o /dev/null -w '%{http_code}' --resolve ${authHost}:443:127.0.0.1 https://${authHost}/oauth2/start | grep -qx 302"
    )

    # Every protected host starts its login on the one host registered with Pocket ID.
    status, location = fetch("https://radarr.${domain}/movies")
    assert status == "307", status
    assert location == "https://${authHost}/oauth2/start?rd=https://radarr.${domain}/movies", location

    status, location = fetch(location)
    assert status == "302", status
    login = urllib.parse.urlsplit(location)
    query = urllib.parse.parse_qs(login.query)
    assert f"{login.scheme}://{login.netloc}{login.path}" == "https://id.kube.kalski.xyz/authorize", location
    assert query["client_id"] == ["zima"], query
    assert query["redirect_uri"] == ["https://${authHost}/oauth2/callback"], query
    assert query["code_challenge_method"] == ["S256"], query
    # allowed-group only works if Pocket ID is asked for the groups claim.
    assert "groups" in query["scope"][0].split(), query

    machine.fail("journalctl -u backend | grep -q 'GET /movies'")

    # Sonarr trusts every request it gets, so it must be reachable only through nginx.
    machine.wait_for_open_port(8989)
    listeners = machine.succeed("ss -ltnH 'sport = :8989' | awk '{print $4}'").split()
    assert listeners == ["127.0.0.1:8989"], listeners

    # The generated cookie secret is kept, so sessions survive restarts.
    secret = machine.succeed("cat /var/lib/oauth2-proxy-secret/cookie-secret")
    machine.succeed("systemctl restart oauth2-proxy-cookie-secret")
    assert machine.succeed("cat /var/lib/oauth2-proxy-secret/cookie-secret") == secret
  '';
}
