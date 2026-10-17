{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentEnvironment;
  binaries = {
    codex = ".local/bin/codex";
    claude = ".local/bin/claude";
    opencode = ".opencode/bin/opencode";
  };
  requiredMajors.opencode = 2;
  installed =
    name: binary:
    let
      major = toString requiredMajors.${name};
    in
    if requiredMajors ? ${name} then
      ''{ version=$(${binary} --version) && echo "$version" && [[ $version =~ ([0-9]+)\.[0-9]+ ]] && (( BASH_REMATCH[1] >= ${major} )); }''
    else
      "${binary} --version";
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
        default = lib.unique (lib.mapAttrsToList (_: path: "${cfg.home}/${dirOf path}") binaries);
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
        default = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            name: relativePath:
            let
              check = installed name (lib.escapeShellArg "${cfg.home}/${relativePath}");
            in
            ''
              if ! ${check}; then
                ${lib.getExe cfg.toolInstallers.${name}}
                ${check} || exit 1
              fi
            ''
          ) binaries
        );
      };
    };
  };
}
