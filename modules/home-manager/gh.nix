{
  pkgs,
  ...
}:
{
  programs.gh = {
    enable = true;
    extensions = [ pkgs.gh-stack ];
    # git has no credential helper configured; keep it that way
    gitCredentialHelper.enable = false;
  };
}
