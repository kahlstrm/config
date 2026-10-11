{
  stdenvNoCC,
  fetchurl,
  lib,
}:
let
  version = "1.34.12";
  platforms = {
    x86_64-linux = {
      path = "linux/amd64";
      hash = "90b7b9058ffeb5c10710bb1c73f541eaf426fb1b4e87df435db669de9a2564a2";
    };
    aarch64-linux = {
      path = "linux/arm64";
      hash = "c819e3eb6a540d4f1e6aacaac85580bf0793bd1e7d05095a47407733ccf0cfb7";
    };
    aarch64-darwin = {
      path = "darwin/arm64";
      hash = "0c37a655d8495312c90554b61b9ff8400077e743ae2dc07008a529667a750db9";
    };
  };
  platform = platforms.${stdenvNoCC.hostPlatform.system};
in
# Match the cluster's Kubernetes minor version independently of nixpkgs updates.
stdenvNoCC.mkDerivation {
  pname = "agent-kubectl";
  inherit version;
  src = fetchurl {
    url = "https://dl.k8s.io/release/v${version}/bin/${platform.path}/kubectl";
    sha256 = platform.hash;
  };
  dontUnpack = true;
  dontStrip = true;
  installPhase = ''
    install -Dm755 "$src" "$out/bin/kubectl"
  '';
  meta = {
    mainProgram = "kubectl";
    platforms = builtins.attrNames platforms;
    license = lib.licenses.asl20;
  };
}
