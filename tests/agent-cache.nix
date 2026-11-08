{ pkgs }:
let
  inherit (pkgs) lib;
  endpoint = import ../modules/agents/vm/cache-endpoint.nix;
  hostAddress = "192.168.1.1";
  guestAddress = "192.168.1.2";
  otherAddress = "192.168.1.3";
  # What a guest gets from its settings: the substituter and the name's address.
  client = endpoint.guest { inherit hostAddress; };
  cache = "https://${endpoint.name}:${toString endpoint.port}";
  # A test CA in place of the host's ACME certificate.
  certificates =
    pkgs.runCommand "agent-cache-certificates" { nativeBuildInputs = [ pkgs.openssl ]; }
      ''
        mkdir $out && cd $out
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
          -keyout ca.key -out ca.crt -days 36500 -subj /CN=agent-cache-test-ca
        openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
          -keyout cache.key -out cache.csr -subj /CN=${endpoint.name}
        printf 'subjectAltName=DNS:${endpoint.name}\n' > san
        openssl x509 -req -in cache.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
          -days 36500 -extfile san -out cache.crt
      '';
  address = ip: {
    virtualisation.vlans = [ 1 ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = ip;
        prefixLength = 24;
      }
    ];
    environment.systemPackages = [ pkgs.curl ];
    nix.settings.experimental-features = [ "nix-command" ];
  };
  # Both clients trust the certificate and resolve the name, so only the allow-list
  # tells them apart.
  cacheClient = ip: {
    imports = [ (address ip) ];
    security.pki.certificateFiles = [ "${certificates}/ca.crt" ];
    networking.hosts = client.substituterHosts;
  };
  # Built at run time on the host, so neither client has it.
  hostOnly = pkgs.writeText "host-only.nix" ''
    derivation {
      name = "host-only";
      system = "${pkgs.stdenv.hostPlatform.system}";
      builder = (builtins.storePath "${pkgs.bash}") + "/bin/bash";
      args = [ "-c" "echo built > $out" ];
      # Like a NixOS toplevel: Nix builds it locally unless told to always substitute.
      allowSubstitutes = false;
    }
  '';
in
pkgs.testers.runNixOSTest {
  name = "agent-cache";
  nodes = {
    host =
      { lib, ... }:
      {
        imports = [
          ../modules/agents/vm/cache.nix
          (address hostAddress)
        ];
        # Stand-ins for the host's agent VM declarations; a VM without deployment needs no warm-up.
        options.local.agentVMs = lib.mkOption { type = lib.types.attrs; };
        options.microvm.vms = lib.mkOption { type = lib.types.attrs; };
        config = {
          local.agentVMs.guest.network.guestAddress = guestAddress;
          microvm.vms.guest.evaluatedConfig.config.local.agentEnvironment.deploy.enable = false;
          local.agentVMCache = {
            enable = true;
            tls = {
              sslCertificate = "${certificates}/cache.crt";
              sslCertificateKey = "${certificates}/cache.key";
            };
          };
          # Only nginx's allow-list keeps other machines out.
          networking.firewall.allowedTCPPorts = [ endpoint.port ];
          system.extraDependencies = [ hostOnly ];
        };
      };
    guest = {
      imports = [ (cacheClient guestAddress) ];
      nix.settings.substituters = lib.mkForce [ client.substituter ];
    };
    other = cacheClient otherAddress;
  };
  testScript = ''
    start_all()
    host.wait_for_unit("harmonia.socket")
    host.wait_for_unit("nginx.service")
    guest.wait_for_unit("multi-user.target")
    other.wait_for_unit("multi-user.target")
    guest.wait_until_succeeds("curl --fail --max-time 5 ${cache}/nix-cache-info")
    guest.succeed("curl --fail --max-time 5 ${cache}/nix-cache-info | grep -x 'Priority: 30'")
    # Same certificate and name, but not a guest address.
    other.succeed("curl --silent --max-time 5 --output /dev/null --write-out '%{http_code}' ${cache}/nix-cache-info | grep -x 403")

    path = host.succeed("nix eval --impure --raw --file ${hostOnly} outPath").strip()
    poll = f"nix path-info --option narinfo-cache-negative-ttl 0 --store '${client.substituter}' {path}"
    # A miss before the host builds it does not hide the path once it is there.
    guest.fail(poll)
    host.succeed("nix-build --no-out-link ${hostOnly}")
    guest.succeed(poll)

    # Unsigned paths are refused unless the substituter is trusted.
    download_only = "--option always-allow-substitutes true --max-jobs 0"
    guest.fail(f"nix-store --realise {path} {download_only} --option substituters ${cache}")
    guest.succeed(f"nix-store --realise {path} {download_only}")
    guest.succeed(f"grep -x built {path}")
  '';
}
