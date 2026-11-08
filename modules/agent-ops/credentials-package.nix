{
  writeShellApplication,
  coreutils,
  jq,
  kubectl,
  openssh,
  openssl,
  talosctl,
}:
writeShellApplication {
  name = "ops-credentials";
  runtimeInputs = [
    coreutils
    jq
    kubectl
    openssh
    openssl
    talosctl
  ];
  text = builtins.readFile ./credentials.sh;
}
