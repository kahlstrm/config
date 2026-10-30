# Only Claude Code runs on ops: its managed allow and deny rules (./claude.nix) are what keep
# credential reads behind approval, and other harnesses run reads such as `cat` unasked.
# T3 deep-merges t3Settings into its settings file at every start, so these flags return
# even if toggled in the UI; their CLIs are not installed either.
{ lib, options, ... }:
let
  # T3's built-in drivers besides Claude; each default instance carries its driver's id.
  others = [
    "codex"
    "cursor"
    "grok"
    "fx"
    "opencode"
    "antigravity"
    "pi"
    "muse"
    "acpRegistry"
  ];
in
{
  local.agentEnvironment = {
    harnesses = [ "claude" ];
    t3Settings = options.local.agentEnvironment.t3Settings.default // {
      providerInstances = lib.genAttrs others (driver: {
        inherit driver;
        enabled = false;
      });
    };
  };
}
