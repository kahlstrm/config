{
  config,
  lib,
  pkgs,
  ...
}:
let
  agentHome = config.users.users.agent.home;
  binaries = {
    codex = ".local/bin/codex";
    claude = ".local/bin/claude";
    opencode = ".opencode/bin/opencode";
  };
  installerRuntime = with pkgs; [
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
      runtimeInputs = installerRuntime;
      text = ''
        temporary=$(mktemp)
        trap 'rm -f "$temporary"' EXIT
        curl --fail --silent --show-error --location --connect-timeout 15 --max-time 120 ${lib.escapeShellArg url} -o "$temporary"
        ${command}
      '';
    };
in
{
  options.local.agentEnvironment.toolInstallers = lib.mkOption {
    type = lib.types.attrsOf lib.types.package;
    internal = true;
    description = "Environment CLI installers; replaceable with offline fixtures in tests.";
    default = {
      codex =
        installer "codex" "https://chatgpt.com/codex/install.sh"
          ''CODEX_NON_INTERACTIVE=1 sh "$temporary"'';
      claude = installer "claude" "https://claude.ai/install.sh" ''bash "$temporary" latest'';
      opencode =
        installer "opencode" "https://opencode.ai/install"
          ''bash "$temporary" --no-modify-path'';
    };
  };
  config = {
    programs.nix-ld.libraries = [ pkgs.alsa-lib ];
    environment.systemPackages = with pkgs; [
      bubblewrap
      procps
      socat
    ];
    environment.localBinInPath = true;
    environment.shellInit = ''
      export PATH="$HOME/.opencode/bin:$PATH"
    '';
    systemd.services.agent-tools = {
      description = "Install writable coding agent CLIs";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment.HOME = agentHome;
      path = installerRuntime;
      serviceConfig = {
        User = "agent";
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 60;
        TimeoutStartSec = "15min";
        UMask = "0077";
        NoNewPrivileges = true;
      };
      script = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: relativePath: ''
          if ! ${lib.escapeShellArg "${agentHome}/${relativePath}"} --version; then
            ${lib.getExe config.local.agentEnvironment.toolInstallers.${name}}
            ${lib.escapeShellArg "${agentHome}/${relativePath}"} --version
          fi
        '') binaries
      );
    };
    systemd.services.t3code.environment.PATH = lib.mkForce (
      "${agentHome}/.local/bin:${agentHome}/.opencode/bin:"
      + lib.makeBinPath config.environment.systemPackages
      + ":/run/current-system/sw/bin"
    );
  };
}
