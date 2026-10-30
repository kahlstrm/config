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
    volumeSizes = {
      home = 16 * 1024;
      var = 4 * 1024;
      nix = 32 * 1024;
    };
  };
  # No GitHub App: ops reads the public configuration anonymously and never pushes.
  local.agentGithub.enable = false;
}
