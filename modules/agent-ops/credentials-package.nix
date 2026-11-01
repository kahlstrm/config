{
  writeShellApplication,
  coreutils,
  jq,
  openssl,
  talosctl,
}:
writeShellApplication {
  name = "ops-credentials";
  runtimeInputs = [
    coreutils
    jq
    openssl
    talosctl
  ];
  text = builtins.readFile ./credentials.sh;
}
