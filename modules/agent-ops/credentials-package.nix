{
  writeShellApplication,
  coreutils,
  jq,
  kubectl,
  openssl,
  talosctl,
}:
writeShellApplication {
  name = "ops-credentials";
  runtimeInputs = [
    coreutils
    jq
    kubectl
    openssl
    talosctl
  ];
  text = builtins.readFile ./credentials.sh;
}
