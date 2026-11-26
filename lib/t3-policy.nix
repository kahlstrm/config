# Machine-wide T3 Code managed policy; installed to /etc/t3code/policy.json on
# Linux and "/Library/Application Support/T3Code/policy.json" on macOS.
let
  policyJson = builtins.toJSON {
    schemaVersion = 1;
    organization = "nix-config";
    limits = {
      telemetry = false;
    };
  };
in
{
  darwin =
    { pkgs, ... }:
    let
      policyFile = pkgs.writeText "t3code-policy.json" policyJson;
    in
    {
      key = "t3-policy-darwin";
      config.system.activationScripts.extraActivation.text = ''
        install -d -m 0755 "/Library/Application Support/T3Code"
        install -m 0644 ${policyFile} "/Library/Application Support/T3Code/policy.json"
      '';
    };

  nixos =
    { pkgs, ... }:
    {
      key = "t3-policy-nixos";
      config.environment.etc."t3code/policy.json".source = pkgs.writeText "t3code-policy.json" policyJson;
    };
}
