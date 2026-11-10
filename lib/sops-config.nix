# Renders .sops.yaml: `nix eval --json --file lib/sops-config.nix | jq . > .sops.yaml`
let
  keys = import ./ssh-keys.nix;
in
{
  creation_rules = [
    {
      path_regex = "infra/local-kubernetes/.+\\.sops\\.yaml$";
      encrypted_regex = "^(data|stringData)$";
      key_groups = [ { age = keys.administrators ++ [ keys.kubernetes.klusse ]; } ];
    }
  ]
  # ops' Bambuddy key, encrypted to ops alone; see modules/agent-ops/default.nix.
  ++ (
    if keys.hosts ? "pannu-ops" then
      [
        {
          path_regex = "modules/agent-ops/bambuddy\\.sops\\.yaml$";
          key_groups = [ { age = [ keys.hosts."pannu-ops" ]; } ];
        }
      ]
    else
      [ ]
  );
}
