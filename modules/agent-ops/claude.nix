# Claude Code policy for the ops VM. Delegated threads run at approval-required, so Claude
# asks the operator before anything not allowed here; only managed rules count, and no
# mode skips the prompts. Each allowed command is read-only towards the infrastructure:
# - talosctl health / version: cluster health and versions, no configuration or secrets.
#   (`talosctl get` is left out: with an admin config it returns machine configs and secrets;
#   the agents VM's os:reader access covers routine reads.)
# - terraform init / validate / plan, exact forms only: init installs providers and modules
#   into the checkout, validate is offline, and plan reads state without writing it, apart
#   from the state lock. Flags such as -out, -upgrade or -migrate-state, which write plan
#   files or state, still ask. Plan runs the checkout's code with the credentials, so the
#   checkout changes only through approved commands or the fast-forward pull below.
# - git fetch and git pull --ff-only, exact forms: update the checkout from its upstream
#   branch without choosing another one.
# kubectl is left out: ops has no kubeconfig of its own, and an admin one could read Secrets;
# the agents VM has read-only cluster access.
{ config, lib, ... }:
let
  credentialDirectories = [
    config.age.secretsDir
    config.age.secretsMountPoint
  ];
in
{
  options.local.agentOps.claudePermissions = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf lib.types.str);
    readOnly = true;
    default = {
      allow = [
        "Bash(talosctl health *)"
        "Bash(talosctl version *)"
        "Bash(terraform init)"
        "Bash(terraform validate)"
        "Bash(terraform plan)"
        "Bash(terraform plan -no-color)"
        "Bash(git fetch)"
        "Bash(git pull --ff-only)"
      ];
      # Absolute paths take a double slash; the rules also cover cat, head and similar in Bash.
      deny = lib.concatMap (directory: [
        "Read(/${directory}/**)"
        "Edit(/${directory}/**)"
      ]) credentialDirectories;
    };
    description = "Claude Code permission rules for ops, written to its managed settings.";
  };
  config.environment.etc."claude-code/managed-settings.json".text = builtins.toJSON {
    # User, project and command-line rules are ignored, and prompts offer no always-allow.
    allowManagedPermissionRulesOnly = true;
    disableAutoMode = "disable";
    permissions = config.local.agentOps.claudePermissions // {
      disableBypassPermissionsMode = "disable";
    };
  };
}
