{ pkgs }:
let
  inherit (pkgs) lib;
  deployedVersion = lib.head (
    builtins.match ".*pocket-id:v([0-9]+\\.[0-9]+)\\..*" (
      builtins.readFile ../../platform/pocket-id/pocket-id.yaml
    )
  );
  apiKey = pkgs.writeText "pocket-id-api-key" "test-static-api-key-0123456789";
  writeIdentity = name: value: pkgs.writeText "${name}.json" (builtins.toJSON value);

  kalle = {
    username = "kalle";
    email = "kalle@example.com";
    emailVerified = true;
    firstName = "Kalle";
    lastName = "Test";
    isAdmin = true;
  };
  admins = {
    name = "admins";
    friendlyName = "Administrators";
    members = [ "kalle" ];
  };
  client = id: callback: {
    inherit id;
    name = id;
    callbackURLs = [ callback ];
    isPublic = true;
    pkceEnabled = true;
    allowedGroups = [ "admins" ];
  };
  grafana = client "grafana" "https://grafana.example.com/login/generic_oauth";
  oauth2Proxy = client "oauth2-proxy" "https://auth.example.com/oauth2/callback";

  initial = writeIdentity "initial" {
    users = [ kalle ];
    groups = [ admins ];
    clients = [
      grafana
      oauth2Proxy
    ];
  };
  changed = writeIdentity "changed" {
    users = [ (kalle // { firstName = "Renamed"; }) ];
    groups = [ admins ];
    clients = [ (grafana // { callbackURLs = [ "https://grafana.example.com/new" ]; }) ];
  };
  noClients = writeIdentity "no-clients" {
    users = [ kalle ];
    groups = [ admins ];
    clients = [ ];
  };
  dropAdmins = writeIdentity "drop-admins" {
    users = [ ];
    groups = [ ];
    clients = [ (removeAttrs grafana [ "allowedGroups" ]) ];
  };

  sync = pkgs.writeShellScript "pocket-id-sync" ''
    export POCKET_ID_URL=http://localhost:1411 POCKET_ID_API_KEY_FILE=${apiKey}
    exec ${pkgs.python3}/bin/python3 ${./pocket-id-sync.py} "$@"
  '';
in
assert lib.assertMsg (
  lib.versions.majorMinor pkgs.pocket-id.version == deployedVersion
) "nixpkgs has Pocket ID ${pkgs.pocket-id.version}, but the cluster runs ${deployedVersion}";
{
  name = "pocket-id-sync";

  nodes.machine = {
    services.pocket-id = {
      enable = true;
      settings.APP_URL = "http://localhost:1411";
      credentials = {
        ENCRYPTION_KEY = pkgs.writeText "pocket-id-encryption-key" "SUeAyRRFZ1uf03ClOE+o++BVENSE/Ptb9YFRF2Sk+zM=";
        STATIC_API_KEY = apiKey;
      };
    };
    environment.systemPackages = [ pkgs.jq ];
  };

  testScript = ''
    import json

    def api(method, path, body=None):
        data = f"-d '{json.dumps(body)}' -H 'Content-Type: application/json'" if body else ""
        out = machine.succeed(
            f"curl -sfg -X {method} -H \"X-API-Key: $(cat ${apiKey})\" {data} 'http://localhost:1411/api{path}'"
        )
        return json.loads(out) if out else None

    def ids(path, key="id"):
        return sorted(item[key] for item in api("GET", f"{path}?pagination[limit]=100")["data"])

    machine.wait_for_unit("pocket-id.service")
    machine.wait_until_succeeds("curl -sf http://localhost:1411/healthz")

    with subtest("creates declared state and deletes undeclared clients and groups"):
        api("POST", "/oidc/clients", {"id": "stale", "name": "stale", "callbackURLs": ["https://stale.example.com/cb"]})
        api("POST", "/user-groups", {"name": "old", "friendlyName": "Old"})
        machine.succeed("${sync} ${initial}")
        assert ids("/oidc/clients") == ["grafana", "oauth2-proxy"], ids("/oidc/clients")
        assert ids("/user-groups", "name") == ["admins"], ids("/user-groups", "name")
        grafana = api("GET", "/oidc/clients/grafana")
        assert grafana["isGroupRestricted"] and grafana["isPublic"], grafana
        assert [g["name"] for g in grafana["allowedUserGroups"]] == ["admins"], grafana
        group = api("GET", "/user-groups/" + grafana["allowedUserGroups"][0]["id"])
        assert [u["username"] for u in group["users"]] == ["kalle"], group

    with subtest("a second run changes nothing"):
        output = machine.succeed("${sync} ${initial}")
        assert output.strip() == "Pocket ID matches the declared state", output

    with subtest("updates changed fields and deletes removed clients"):
        machine.succeed("${sync} ${changed}")
        assert ids("/oidc/clients") == ["grafana"], ids("/oidc/clients")
        assert api("GET", "/oidc/clients/grafana")["callbackURLs"] == ["https://grafana.example.com/new"]
        user = api("GET", "/users?search=kalle")["data"][0]
        assert user["firstName"] == "Renamed", user

    with subtest("refuses to sync without clients"):
        machine.fail("${sync} ${noClients}")
        assert ids("/oidc/clients") == ["grafana"], ids("/oidc/clients")

    with subtest("never deletes users or groups that still have members"):
        machine.fail("${sync} ${dropAdmins}")
        assert ids("/user-groups", "name") == ["admins"], ids("/user-groups", "name")
        assert "kalle" in ids("/users", "username"), ids("/users", "username")
        assert not api("GET", "/oidc/clients/grafana")["isGroupRestricted"]
  '';
}
