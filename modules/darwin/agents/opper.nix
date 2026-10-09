{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentHost.opper;
  user = config.system.primaryUser;
  home = config.users.users.${user}.home;
  baseUrl = "https://api.opper.ai/v3/compat";
  keyCommand = "/usr/bin/security find-generic-password -a ${user} -s ${cfg.keychainItem} -w";
  claudeHome = "${home}/.claude-opper";

  # A second Claude Code configuration next to the default ~/.claude (its own
  # sign-in): Claude Code talks to Opper's Anthropic-compatible
  # endpoint and fetches the key from the keychain on demand.
  claudeSettings = (pkgs.formats.json { }).generate "claude-opper-settings.json" {
    apiKeyHelper = keyCommand;
    model = "sonnet";
    env = {
      ANTHROPIC_BASE_URL = baseUrl;
      # Claude Code doesn't know these models; without this it assumes 1M for
      # the opus slot. The smallest window of the configured models.
      CLAUDE_CODE_MAX_CONTEXT_TOKENS = toString cfg.maxContextTokens;
      ANTHROPIC_DEFAULT_OPUS_MODEL = cfg.claudeModels.opus;
      ANTHROPIC_DEFAULT_SONNET_MODEL = cfg.claudeModels.sonnet;
      ANTHROPIC_DEFAULT_HAIKU_MODEL = cfg.claudeModels.haiku;
    };
  };

  # Loaded through OPENCODE_CONFIG, which OpenCode merges over the global
  # opencode.json: adds the provider without touching the user's own config.
  opencodeConfig = (pkgs.formats.json { }).generate "opencode-opper.json" {
    "$schema" = "https://opencode.ai/config.json";
    provider.opper = {
      npm = "@ai-sdk/openai-compatible";
      name = "Opper";
      options = {
        baseURL = baseUrl;
        apiKey = "{env:OPPER_API_KEY}";
      };
      models = lib.mapAttrs (_: name: { inherit name; }) cfg.opencodeModels;
    };
  };

  claude-opper = pkgs.writeShellScriptBin "claude-opper" ''
    CLAUDE_CONFIG_DIR=${claudeHome} exec ${home}/.local/bin/claude "$@"
  '';

  modelId = lib.types.strMatching "[a-z0-9:._-]+/.+";
in
{
  options.local.agentHost.opper = {
    enable = lib.mkEnableOption "Opper as the model provider for Claude Code (~/.claude-opper) and OpenCode";
    keychainItem = lib.mkOption {
      type = lib.types.str;
      default = "opper-api-key";
      description = "Login keychain item (generic password) holding the Opper API key.";
    };
    claudeModels = lib.mkOption {
      type = lib.types.submodule {
        options = lib.genAttrs [ "opus" "sonnet" "haiku" ] (_: lib.mkOption { type = modelId; });
      };
      description = "Opper model IDs for Claude Code's opus, sonnet (default) and haiku slots.";
    };
    maxContextTokens = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Context window Claude Code assumes: the smallest of claudeModels' windows.";
    };
    t3Instance = lib.mkOption {
      type = lib.types.str;
      default = "claude-opper";
      description = "ID of the T3 Claude provider instance using ~/.claude-opper.";
    };
    opencodeModels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Opper model IDs offered in OpenCode, with display names.";
    };
  };

  config = lib.mkIf cfg.enable {
    local.agentHost.t3.keychainEnvironment.OPPER_API_KEY = cfg.keychainItem;
    local.agentHost.t3.environment.OPENCODE_CONFIG = "${opencodeConfig}";
    environment.variables.OPENCODE_CONFIG = "${opencodeConfig}";
    local.agentHost.t3.settings.providerInstances.${cfg.t3Instance} = {
      driver = "claudeAgent";
      displayName = "Claude · Opper (EU)";
      enabled = true;
      config = {
        homePath = claudeHome;
        customModels = lib.unique (lib.attrValues cfg.claudeModels);
      };
    };
    environment.systemPackages = [ claude-opper ];

    home-manager.users.${user} =
      { lib, ... }:
      {
        home.file.".claude-opper/CLAUDE.md" = lib.mkIf config.local.agentHost.instructions.enable {
          source = config.environment.etc."agent-instructions.md".source;
        };
        # Copied, not linked: Claude Code writes to its own settings. Every
        # switch restores the declared content.
        home.activation.opperClaudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run install -D -m 600 ${claudeSettings} ${claudeHome}/settings.json
        '';
      };
  };
}
