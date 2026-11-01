{ inputs, ... }:
{
  imports = [
    ../modules/agents/environment
    ../modules/agent-ops
    ../modules/agents/vm/guest.nix
    inputs.microvm.nixosModules.microvm
    inputs.agenix.nixosModules.default
  ];
  nixpkgs = {
    # Terraform is unfree.
    config.allowUnfree = true;
    overlays = [ inputs.microvm.overlays.default ];
  };
  local.agentEnvironment = {
    authorizedKeys = (import ../lib/ssh-keys.nix).administrators;
    revision = inputs.self.rev or "dirty";
    coAuthor = "Kalle Ahlström <kalle.ahlstrom@iki.fi>";
    deploy = {
      enable = true;
      configuration = "ops";
      bootMode = "host";
    };
  };
  local.agentVM = {
    name = "ops";
    settings = import ../modules/agents/vm/ops-settings.nix;
    # Root would read the credentials without the approval that guards every other access.
    passwordlessSudo = false;
    diskDirectory = "/mnt/agents/ops";
    # Fits beside agents in pannu's agent disk budget; the system closure is about 3 GiB,
    # so /nix holds a few generations and a deployment build.
    volumeSizes = {
      home = 4 * 1024;
      var = 2 * 1024;
      nix = 12 * 1024;
    };
  };
  # No GitHub App: ops reads the public configuration anonymously and never pushes.
  local.agentGithub.enable = false;
  # Public halves of ops' own GCP key, once uploaded; see modules/agent-ops/default.nix.
  # local.agentOps.gcp = {
  #   serviceAccount = "<account>@infra-464520.iam.gserviceaccount.com";
  #   keyId = "<key ID>";
  # };
}
