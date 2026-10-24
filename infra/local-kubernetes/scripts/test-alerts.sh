#!/usr/bin/env bash
# Run promtool unit tests against the alert rules Prometheus loads: those rendered
# from the kube-prometheus-stack HelmRelease and the repository's PrometheusRules.
#
# Input series may carry __meta_kubernetes_pod_node_name="<node>" as their last
# label. It is replaced with the labels the kube-etcd ServiceMonitor relabels it
# into, so the tests see the same target labels as the cluster.
set -euo pipefail

root=$(realpath "$(dirname "$0")/..")
release=$root/platform/observability/observability.yaml
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

chart_url=$(yq 'select(.kind == "HelmRepository" and .metadata.name == "prometheus-community").spec.url' \
  "$root"/infrastructure/controllers/prometheus-operator-crds.yaml)
yq '.spec.values' "$release" >"$work/values.yaml"
helm template "$(yq '.spec.releaseName' "$release")" "$(yq '.spec.chart.spec.chart' "$release")" \
  --repo "$chart_url" --version "$(yq '.spec.chart.spec.version' "$release")" \
  --namespace "$(yq '.metadata.namespace' "$release")" -f "$work/values.yaml" >"$work/chart.yaml"

find "$root" -name kustomization.yaml -exec dirname {} \; | sort | xargs -I{} kustomize build {} >"$work/repo.yaml"
# Parent kustomizations include their children, so each rule appears more than once.
yq ea '[.] | map(select(.kind == "PrometheusRule")) | unique_by(.metadata.namespace + "/" + .metadata.name)
  | map(.spec.groups[]) | {"groups": .}' "$work/chart.yaml" "$work/repo.yaml" \
  >"$work/rules.yaml"

etcd_relabelings=$(yq ea -o json '[.] | map(select(.kind == "ServiceMonitor" and .metadata.name == "*kube-etcd")
  | .spec.endpoints[].relabelings[])' "$work/chart.yaml")
if jq -e 'any(.[]; (.action // "replace") != "replace" or .sourceLabels != ["__meta_kubernetes_pod_node_name"])' \
  <<<"$etcd_relabelings" >/dev/null; then
  echo "kube-etcd ServiceMonitor has relabelings this script cannot model: $etcd_relabelings" >&2
  exit 1
fi
node_labels=$(jq -r 'map(",\(.targetLabel)=\"${node}\"") | join("")' <<<"$etcd_relabelings")

for test in "$root"/platform/observability/tests/*.yaml; do
  echo "${test#"$root"/}"
  NODE_LABELS=$node_labels yq '.rule_files = ["rules.yaml"]
    | .tests[].input_series[].series |= sub(",\s*__meta_kubernetes_pod_node_name=\"(?P<node>[^\"]*)\"", strenv(NODE_LABELS))' \
    "$test" >"$work/$(basename "$test")"
  promtool test rules "$work/$(basename "$test")"
done
