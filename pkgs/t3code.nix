# T3 Code 0.1.11 until nixpkgs ships it
{
  lib,
  t3code,
  fetchFromGitHub,
}:
let
  unwrapped =
    if lib.versionAtLeast t3code.version "0.1.11" then
      t3code.unwrapped
    else
      t3code.unwrapped.overrideAttrs (
        finalAttrs: old: {
          version = "0.1.11";
          src = fetchFromGitHub {
            owner = "pingdotgg";
            repo = "t3code";
            tag = "v${finalAttrs.version}";
            hash = "sha256-oI8gyTWFgtTmVK+0cVQaEcfO8EzxUUOW5s8JFG/z/U8=";
          };
          pnpmDeps = old.pnpmDeps.overrideAttrs {
            outputHash = "sha256-s/vm8Ox4o/AYpNC/amYP1KFWwh7SY5bCmVBuIJn9f/c=";
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
      # Wake PR watches on new comments, not edits; review bots rewrite summaries
      # in place (pingdotgg/t3code#36046).
      ./t3code-pr-watch-ignore-edits.patch
    ];
  });
}
