{ lib, ... }:

let
  disabledSkills = [ "browser:control-in-app-browser" ];
  disabledPlugins = [
    "computer-use@openai-bundled"
    "unified-computer-use@openai-bundled"
  ];
  disabledMcpServers = [ ];
  skillConfig = lib.concatMapStringsSep ", " (
    name: "{ name = ${builtins.toJSON name}, enabled = false }"
  ) disabledSkills;
  disableEntries =
    section: names:
    lib.concatMap (name: [
      "-c"
      "${section}.${builtins.toJSON name}.enabled=false"
    ]) names;
  codex = lib.escapeShellArgs (
    [
      "command"
      "codex"
      "-c"
      "skills.config=[${skillConfig}]"
    ]
    ++ disableEntries "plugins" disabledPlugins
    ++ disableEntries "mcp_servers" disabledMcpServers
  );
in
{
  programs.zsh.shellAliases = {
    inherit codex;
    codexc = "${codex} resume --last";
    codexr = "${codex} resume";
  };
}
