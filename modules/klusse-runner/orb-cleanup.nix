# The Go program that records orbs' git facts at pause and removes stopped orbs by rule
# (./orb-cleanup/main.go).
{ buildGoModule, git }:
buildGoModule {
  pname = "orb-cleanup";
  version = "1.0.0";
  src = ./orb-cleanup;
  vendorHash = null;
  env.CGO_ENABLED = "0";
  nativeCheckInputs = [ git ];
  doCheck = true;
  meta.mainProgram = "orb-cleanup";
}
