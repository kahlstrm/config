# T3 Code 0.1.0 until nixpkgs ships it: https://github.com/NixOS/nixpkgs/pull/575132
{
  lib,
  t3code,
  fetchFromGitHub,
}:
if lib.versionAtLeast t3code.version "0.1.0" then
  t3code
else
  t3code.override {
    t3code-unwrapped = t3code.unwrapped.overrideAttrs (
      finalAttrs: old: {
        version = "0.1.0";
        src = fetchFromGitHub {
          owner = "pingdotgg";
          repo = "t3code";
          tag = "v${finalAttrs.version}";
          hash = "sha256-P82DqoY1E9wtROwu5Nr7MB/I1PdmZHWXXR4nRa4GWXM=";
        };
        pnpmDeps = old.pnpmDeps.overrideAttrs {
          outputHash = "sha256-oX4tOu20tYO3ci7VvSEL8eFgxAYWp5HlQFSfAWJGJmg=";
        };
      }
    );
  }
