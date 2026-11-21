# T3 Code 0.1.10 until nixpkgs ships it
{
  lib,
  t3code,
  fetchFromGitHub,
}:
let
  unwrapped =
    if lib.versionAtLeast t3code.version "0.1.10" then
      t3code.unwrapped
    else
      t3code.unwrapped.overrideAttrs (
        finalAttrs: old: {
          version = "0.1.11";
          src = fetchFromGitHub {
            owner = "pingdotgg";
            repo = "t3code";
            tag = "v${finalAttrs.version}";
            hash = "sha256-zhScbDGW+bD2T7++YRUPY/y83SGE2080LxcGw3Txrso=";
          };
          pnpmDeps = old.pnpmDeps.overrideAttrs {
            outputHash = "sha256-BFPdwtpZRCeoHJANsrLee91pzSVbasfJRa+Ax7Gr60o=";
          };
        }
      );
in
t3code.override {
  t3code-unwrapped = unwrapped.overrideAttrs (old: {
    patches = old.patches or [ ] ++ [
      # Lets the host provide the preview browser instead of T3 downloading one,
      # which needs libraries NixOS does not expose to downloaded binaries.
      ./t3code-preview-browser-path.patch
    ];
  });
}
