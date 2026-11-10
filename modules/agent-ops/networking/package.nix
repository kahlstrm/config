{
  buildGoModule,
  runtimeDirectory,
  project,
}:
buildGoModule {
  pname = "ops-networking";
  version = "1.0.0";
  src = ./.;
  vendorHash = null;
  env.CGO_ENABLED = "0";
  ldflags = [
    "-X main.runtimeDirectory=${runtimeDirectory}"
    "-X main.project=${project}"
  ];
  doCheck = true;
  meta.mainProgram = "ops-networking";
}
