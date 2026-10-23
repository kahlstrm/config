# T3 Code 0.1.2 until nixpkgs ships it
{
  lib,
  t3code,
  fetchFromGitHub,
}:
let
  unwrapped =
    if lib.versionAtLeast t3code.version "0.1.2" then
      t3code.unwrapped
    else
      t3code.unwrapped.overrideAttrs (
        finalAttrs: old: {
          version = "0.1.2";
          src = fetchFromGitHub {
            owner = "pingdotgg";
            repo = "t3code";
            tag = "v${finalAttrs.version}";
            hash = "sha256-C5l7541kanlsukhswrAEu8GFpr/YpWDnofJ5dlg7+LM=";
          };
          pnpmDeps = old.pnpmDeps.overrideAttrs {
            outputHash = "sha256-xRmOrOZbBljaF1IJr0JFUFzdhkld6+ehLIlpVOg/J3E=";
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
