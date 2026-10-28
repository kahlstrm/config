{
  config,
  lib,
  pkgs,
  ...
}:
{
  # The desktop app's server reads these at start, so a running app picks them up after a restart.
  home.activation.t3Settings = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    import ../../lib/t3-settings.nix {
      inherit lib;
      jq = lib.getExe pkgs.jq;
      home = config.home.homeDirectory;
      settings.branchNamingMode = "semantic";
    }
  );
}
