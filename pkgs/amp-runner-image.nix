# The klusse runner's image: the flake's pinned amp-cli and the read-only tools its threads use,
# run as uid 65532 under a restricted pod (infra/docs/adr/2026-11-09-one-runner-per-managed-thing.md).
# HOME and /tmp are emptyDir mounts: Amp writes its state to HOME and its Bun runtime loads a
# native module it unpacks to /tmp, so /tmp must allow exec.
{
  lib,
  dockerTools,
  runCommand,
  writeText,
  amp-cli,
  bashInteractive,
  cacert,
  coreutils,
  curl,
  findutils,
  gawk,
  git,
  gnugrep,
  gnused,
  jq,
  kubectl,
}:
let
  user = "runner";
  uid = "65532";
  home = "/home/${user}";
  tools = [
    amp-cli
    bashInteractive
    coreutils
    curl
    findutils
    gawk
    git
    gnugrep
    gnused
    jq
    kubectl
  ];
  # git and ssh look up the current user; an unknown uid makes them fail.
  passwd = writeText "passwd" ''
    root:x:0:0:root:/root:/bin/sh
    ${user}:x:${uid}:${uid}:${user}:${home}:/bin/bash
    nobody:x:65534:65534:nobody:/var/empty:/bin/sh
  '';
  group = writeText "group" ''
    root:x:0:
    ${user}:x:${uid}:
    nobody:x:65534:
  '';
  root = runCommand "amp-runner-root" { } ''
    mkdir -p $out/etc $out${home} $out/tmp
    cp ${passwd} $out/etc/passwd
    cp ${group} $out/etc/group
  '';
in
dockerTools.buildLayeredImage {
  name = "amp-runner";
  tag = amp-cli.version;
  contents = tools ++ [
    root
    cacert
    dockerTools.binSh
    dockerTools.usrBinEnv
  ];
  fakeRootCommands = ''
    chown ${uid}:${uid} .${home}
    chmod 1777 ./tmp
  '';
  enableFakechroot = false;
  config = {
    User = "${uid}:${uid}";
    WorkingDir = home;
    Entrypoint = [ (lib.getExe amp-cli) ];
    Env = [
      "HOME=${home}"
      "USER=${user}"
      "PATH=${lib.makeBinPath tools}"
      "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
      "GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt"
    ];
  };
}
