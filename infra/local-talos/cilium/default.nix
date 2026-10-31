# Talos's Cilium manifest: the chart pinned in chart.json rendered with
# values.yaml for the Kubernetes version in ../versions.json, then
# post-render.yq for what the values cannot set. `just
# cilium-render` copies it to ../manifests/cilium.yaml; the cilium-manifest
# flake check fails while that copy differs.
{
  runCommand,
  fetchurl,
  kubernetes-helm,
  yq-go,
}:
let
  pin = builtins.fromJSON (builtins.readFile ./chart.json);
  kubernetes = (builtins.fromJSON (builtins.readFile ../versions.json)).kubernetes;
  chart = fetchurl {
    url = "https://helm.cilium.io/cilium-${pin.version}.tgz";
    inherit (pin) hash;
  };
in
runCommand "cilium-${pin.version}.yaml"
  {
    nativeBuildInputs = [
      kubernetes-helm
      yq-go
    ];
    passthru = {
      inherit chart;
      inherit (pin) version;
    };
  }
  ''
    export HOME="$TMPDIR"
    {
      echo "# Generated from infra/local-talos/cilium by \`just cilium-render\`; do not edit."
      helm template cilium ${chart} --namespace kube-system --kube-version ${kubernetes} --values ${./values.yaml} \
        | yq --from-file ${./post-render.yq}
    } >"$out"
  ''
