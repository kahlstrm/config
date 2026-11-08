{
  writeShellApplication,
  writeText,
  python3,
  git,
  nix,
  coreutils,
  repository,
  configuration,
  bootMode,
  waitForSubstituter ? null,
  platform ? "nixos",
  user ? null,
}:
let
  settings = writeText "agent-deploy.json" (
    builtins.toJSON (
      {
        inherit repository configuration bootMode;
      }
      // (if platform == "nixos" then { } else { inherit platform user; })
      // (if waitForSubstituter == null then { } else { inherit waitForSubstituter; })
    )
  );
in
writeShellApplication {
  name = "agent-deploy-runner";
  runtimeInputs = [
    git
    nix
    coreutils
  ];
  text = ''
    export GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_GLOBAL=/dev/null
    export GIT_TERMINAL_PROMPT=0 NIX_USER_CONF_FILES=/dev/null
    exec ${python3}/bin/python3 ${./deploy.py} ${settings} "$@"
  '';
}
