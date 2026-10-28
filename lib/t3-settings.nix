# Shell lines that merge `settings` into T3's settings file; other settings stay editable in the UI.
{
  lib,
  jq,
  home,
  settings,
}:
''
  settings=${lib.escapeShellArg "${home}/.t3/userdata/settings.json"}
  mkdir -p "''${settings%/*}" && touch "$settings"
  if merged=$(${jq} -s --argjson managed ${lib.escapeShellArg (builtins.toJSON settings)} '(add // {}) * $managed' "$settings"); then
    echo "$merged" > "$settings"
  else
    echo "$settings is not valid JSON; leaving it for T3 to report" >&2
  fi
''
