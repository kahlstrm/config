{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentEnvironment;
  harnesses = {
    codex.path = ".local/bin/codex";
    claude.path = ".local/bin/claude";
    opencode = {
      path = ".opencode/bin/opencode";
      minimumMajor = 2;
    };
  };
  binaries = lib.filterAttrs (name: _: lib.elem name cfg.harnesses) harnesses;
  runtime = with pkgs; [
    bash
    curl
    coreutils
    findutils
    gawk
    gnugrep
    gnused
    gnutar
    gzip
    jq
    zstd
  ];
  installer =
    name: url: command:
    pkgs.writeShellApplication {
      name = "install-${name}";
      runtimeInputs = runtime;
      text = ''
        temporary=$(mktemp)
        trap 'rm -f "$temporary"' EXIT
        curl --fail --silent --show-error --location --connect-timeout 15 --max-time 120 ${lib.escapeShellArg url} -o "$temporary"
        ${command}
      '';
    };
in
{
  options.local.agentEnvironment = {
    harnesses = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (lib.attrNames harnesses));
      default = lib.attrNames harnesses;
      description = "Coding agent CLIs that agent-tools installs into the agent's home.";
    };
    toolInstallers = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      internal = true;
      description = "Environment CLI installers; replaceable with offline fixtures in tests.";
      default = {
        codex =
          installer "codex" "https://chatgpt.com/codex/install.sh"
            ''CODEX_NON_INTERACTIVE=1 sh "$temporary"'';
        claude = installer "claude" "https://claude.ai/install.sh" ''bash "$temporary" latest'';
        opencode =
          installer "opencode" "https://opencode.ai/v2/install"
            ''bash "$temporary" --no-modify-path'';
      };
    };
    provisioning.tools = {
      runtime = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        internal = true;
        readOnly = true;
        default = runtime;
      };
      directories = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        internal = true;
        readOnly = true;
        description = "Directories the native installers place agent CLIs in, for service and shell PATHs.";
        default = lib.unique (lib.mapAttrsToList (_: binary: "${cfg.home}/${dirOf binary.path}") binaries);
      };
      path = lib.mkOption {
        type = lib.types.str;
        internal = true;
        readOnly = true;
        description = "PATH prefix with a trailing colon, ready to prepend.";
        default = lib.concatMapStrings (directory: "${directory}:") cfg.provisioning.tools.directories;
      };
      script = lib.mkOption {
        type = lib.types.lines;
        internal = true;
        readOnly = true;
        description = "Installs each missing or outdated agent CLI and checks that it runs.";
        default = ''
          installed() {
            local version
            version=$("$1" --version) || return
            echo "$version"
            [[ $version =~ ([0-9]+)\. ]] && (( BASH_REMATCH[1] >= $2 ))
          }
        ''
        + lib.concatStrings (
          lib.mapAttrsToList (
            name:
            {
              path,
              minimumMajor ? 0,
            }:
            let
              installed = "installed ${lib.escapeShellArg "${cfg.home}/${path}"} ${toString minimumMajor}";
            in
            ''
              if ! ${installed}; then
                ${lib.getExe cfg.toolInstallers.${name}}
                ${installed} || exit 1
              fi
            ''
          ) binaries
        );
      };
    };
  };
}
