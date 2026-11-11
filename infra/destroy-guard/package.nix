{ buildGoModule, git }:
buildGoModule {
  pname = "destroy-guard";
  version = "1.0.0";
  src = ./.;
  vendorHash = null;
  env.CGO_ENABLED = "0";
  nativeCheckInputs = [ git ];
  doCheck = true;
}
