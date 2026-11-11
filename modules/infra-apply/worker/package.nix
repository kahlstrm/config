{ buildGoModule, git }:
buildGoModule {
  pname = "infra-apply-worker";
  version = "1.0.0";
  src = ./.;
  vendorHash = null;
  env.CGO_ENABLED = "0";
  # TestMergedPRs builds a repository.
  nativeCheckInputs = [ git ];
  doCheck = true;
  meta.mainProgram = "infra-apply-worker";
}
