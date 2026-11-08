# The Go deployment runner; deploy-package.nix wraps it with its fixed settings.
{ buildGoModule }:
buildGoModule {
  pname = "agent-deploy-runner";
  version = "1.0.0";
  src = ./deploy;
  vendorHash = null;
  env.CGO_ENABLED = "0";
  doCheck = true;
}
