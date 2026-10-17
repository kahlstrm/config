{
  pkgs,
  ...
}:
{
  programs.gh = {
    enable = true;
    extensions = import ../../lib/gh-extensions.nix pkgs;
    # git has no credential helper configured; keep it that way
    gitCredentialHelper.enable = false;
  };
}
