# Every sops file a machine decrypts with sops-nix is encrypted to host keys alone (`hosts` in
# lib/ssh-keys.nix), so no maintainer key or other recipient reads it. infra/'s files, which
# maintainers and Flux decrypt, follow .sops.yaml's rules there instead.
{ pkgs }:
let
  inherit (pkgs) lib;
  hosts = lib.attrValues (import ../lib/ssh-keys.nix).hosts;
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.difference (lib.fileset.fileFilter (
      file: lib.hasSuffix ".sops.yaml" file.name && file.name != ".sops.yaml"
    ) ../.) ../infra;
  };
in
pkgs.runCommand "agent-sops-recipients" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
  printf '%s\n' ${lib.escapeShellArgs hosts} > hosts
  failed=0
  cd ${src}
  while IFS= read -r file; do
    ok=1
    others=$(yq '[.sops.key_groups, .sops.kms, .sops.gcp_kms, .sops.hckms, .sops.azure_kv, .sops.hc_vault, .sops.pgp] | map(select(. != null) | length) | .[] | select(. > 0)' "$file")
    recipients=$(yq '.sops.age[].recipient' "$file")
    if [ -n "$others" ] || [ -z "$recipients" ]; then
      echo "$file: not encrypted to age recipients alone" >&2
      ok=0
    fi
    while IFS= read -r recipient; do
      if [ -n "$recipient" ] && ! grep -qxF "$recipient" "$NIX_BUILD_TOP/hosts"; then
        echo "$file: recipient $recipient is not a host key in lib/ssh-keys.nix" >&2
        ok=0
      fi
    done <<< "$recipients"
    if [ "$ok" = 1 ]; then echo "$file: host keys only"; else failed=1; fi
  done < <(find . -type f | sort)
  [ "$failed" = 0 ]
  touch $out
''
