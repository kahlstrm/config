set -euo pipefail

manifests=$1
kustomize build "$manifests" | yq --output-format=json '.' | jq -se '
  (map({key: .kind, value: .}) | from_entries) as $by_kind |
  $by_kind.ClusterRole.rules as $rules |
  $by_kind.ServiceAccount as $reader |
  $by_kind.ClusterRoleBinding as $binding |
  $by_kind.Role as $monitoring_api |
  $by_kind.RoleBinding as $monitoring_api_binding |
  ["*", "secrets", "pods/exec", "pods/attach", "pods/portforward",
   "pods/ephemeralcontainers", "pods/proxy", "services/proxy", "nodes/proxy",
   "serviceaccounts/token", "certificatesigningrequests"] as $denied |
  def check($condition; $message): if $condition then true else error($message) end;
  def allows($group; $resource; $verb):
    any($rules[]; (.apiGroups | index($group)) and (.resources | index($resource)) and (.verbs | index($verb)));

  check(all($rules[];
      (.verbs - ["get", "list", "watch"] | length == 0) and
      (.apiGroups | index("*") | not) and
      (.nonResourceURLs // [] | length == 0) and
      ([.resources[] | select(. as $resource | $denied | index($resource))] | length == 0));
    "The debugging role must exclude mutations, wildcards, credentials and interactive/proxy access.") and
  check(all([
      ["", "pods", "list"], ["", "pods/log", "get"], ["", "configmaps", "get"],
      ["", "events", "watch"], ["", "nodes", "get"], ["", "persistentvolumeclaims", "get"],
      ["apps", "deployments", "get"], ["discovery.k8s.io", "endpointslices", "list"],
      ["metrics.k8s.io", "pods", "list"], ["metrics.k8s.io", "nodes", "list"],
      ["kustomize.toolkit.fluxcd.io", "kustomizations", "get"],
      ["helm.toolkit.fluxcd.io", "helmreleases", "get"], ["cert-manager.io", "certificates", "get"],
      ["metallb.io", "ipaddresspools", "get"], ["openebs.io", "diskpools", "get"],
      ["monitoring.coreos.com", "prometheusrules", "get"]
    ][]; allows(.[0]; .[1]; .[2]));
    "The role must support workload, log, event, node, storage, networking, metric and controller diagnostics.") and
  check(
    $binding.roleRef == {apiGroup: "rbac.authorization.k8s.io", kind: "ClusterRole", name: $by_kind.ClusterRole.metadata.name} and
    $binding.subjects == [{kind: "ServiceAccount", name: $reader.metadata.name, namespace: $reader.metadata.namespace}] and
    $reader.automountServiceAccountToken == false;
    "Bind only the dedicated service account, with automatic token mounting disabled.") and
  check(
    $monitoring_api.metadata.namespace == "monitoring" and
    $monitoring_api.rules == [{
      apiGroups: [""], resources: ["services/proxy"], verbs: ["get"],
      resourceNames: ["observability-kube-prometh-prometheus:9090", "observability-kube-prometh-alertmanager:9093"]
    }] and
    $monitoring_api_binding.metadata.namespace == "monitoring" and
    $monitoring_api_binding.roleRef == {apiGroup: "rbac.authorization.k8s.io", kind: "Role", name: $monitoring_api.metadata.name} and
    $monitoring_api_binding.subjects == $binding.subjects;
    "Proxy access is limited to GET requests to the Prometheus and Alertmanager web ports.") and
  check(
    all(.[] | select(. != $monitoring_api and . != $monitoring_api_binding);
      .kind == "Namespace" or (.metadata.namespace // $by_kind.Namespace.metadata.name) == $by_kind.Namespace.metadata.name) and
    $by_kind.Namespace.metadata.labels["pod-security.kubernetes.io/enforce"] == "restricted";
    "The reader must live in its own restricted namespace.")
' > /dev/null
