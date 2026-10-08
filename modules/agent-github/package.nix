{ buildGoModule, git }:
buildGoModule {
  pname = "agent-credentials";
  version = "1.0.0";
  src = ./credentials;
  vendorHash = null;
  env.CGO_ENABLED = "0";
  nativeCheckInputs = [ git ];
  doCheck = true;
}
