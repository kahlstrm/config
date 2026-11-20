# Offline stand-ins for the native installers; opencode fails once to exercise retries.
{ pkgs, lib }:
lib.genAttrs [ "antigravity" "codex" "claude" "opencode" ] (
  name:
  pkgs.writeShellScriptBin "install-${name}" ''
    set -eu
    printf 'installer dependencies\n' | awk '{ print $0 }' > /dev/null
    echo ${name} >> "$HOME/installations"
    if [ ${name} = opencode ] && [ ! -f "$HOME/retry-installation" ]; then
      touch "$HOME/retry-installation"
      exit 1
    fi
    directory="$HOME/.local/bin"
    binary=${name}
    if [ ${name} = opencode ]; then directory="$HOME/.opencode/bin"; fi
    if [ ${name} = antigravity ]; then binary=agy; fi
    mkdir -p "$directory"
    printf '#!${pkgs.runtimeShell}\necho 2.1.280\n' > "$directory/$binary"
    chmod +x "$directory/$binary"
  ''
)
