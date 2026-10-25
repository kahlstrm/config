set -euo pipefail

manifests=$1
kustomize build "$manifests" | yq --output-format=json '.' | jq -se '
  . as $all |
  def one($kind; $namespace; $name):
    [$all[] | select(.kind == $kind and (.metadata.namespace // "") == $namespace and .metadata.name == $name)] |
    if length == 1 then .[0] else error("Expected exactly one \($kind) \($namespace)/\($name).") end;
  def check($condition; $message): if $condition then true else error($message) end;

  one("Namespace"; ""; "agent-debug") as $reader_namespace |
  one("ServiceAccount"; "agent-debug"; "agent-debug-reader") as $reader |
  one("ClusterRole"; ""; "agent-debug-reader") as $role |
  one("ClusterRoleBinding"; ""; "agent-debug-reader") as $binding |
  one("Role"; "monitoring"; "agent-debug-monitoring-api") as $monitoring_api |
  one("RoleBinding"; "monitoring"; "agent-debug-monitoring-api") as $monitoring_api_binding |
  one("Namespace"; ""; "agent-sandbox") as $sandbox |
  one("ServiceAccount"; "agent-sandbox"; "default") as $sandbox_default |
  one("Role"; "agent-sandbox"; "agent-sandbox") as $sandbox_role |
  one("RoleBinding"; "agent-sandbox"; "agent-sandbox") as $sandbox_binding |
  one("NetworkPolicy"; "agent-sandbox"; "pod-network-only") as $sandbox_policy |
  one("ResourceQuota"; "agent-sandbox"; "agent-sandbox") as $sandbox_quota |
  one("ValidatingAdmissionPolicy"; ""; "agent-sandbox-images") as $sandbox_images |
  one("ValidatingAdmissionPolicyBinding"; ""; "agent-sandbox-images") as $sandbox_images_binding |
  [{kind: "ServiceAccount", name: $reader.metadata.name, namespace: $reader.metadata.namespace}] as $subjects |
  $role.rules as $rules |
  ["*", "secrets", "pods/exec", "pods/attach", "pods/portforward",
   "pods/ephemeralcontainers", "pods/proxy", "services/proxy", "nodes/proxy",
   "serviceaccounts/token", "certificatesigningrequests"] as $denied |
  def allows($group; $resource; $verb):
    any($rules[]; (.apiGroups | index($group)) and (.resources | index($resource)) and (.verbs | index($verb)));
  def restricted: .metadata.labels["pod-security.kubernetes.io/enforce"] == "restricted";

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
    $binding.roleRef == {apiGroup: "rbac.authorization.k8s.io", kind: "ClusterRole", name: $role.metadata.name} and
    $binding.subjects == $subjects and
    $reader.automountServiceAccountToken == false;
    "Bind only the dedicated service account, with automatic token mounting disabled.") and
  check(
    $monitoring_api.rules == [{
      apiGroups: [""], resources: ["services/proxy"], verbs: ["get"],
      resourceNames: ["observability-kube-prometh-prometheus:9090", "observability-kube-prometh-alertmanager:9093"]
    }] and
    $monitoring_api_binding.roleRef == {apiGroup: "rbac.authorization.k8s.io", kind: "Role", name: $monitoring_api.metadata.name} and
    $monitoring_api_binding.subjects == $subjects;
    "Proxy access is limited to GET requests to the Prometheus and Alertmanager web ports.") and
  check(
    ($reader_namespace | restricted) and
    all($all[] | select(.metadata.namespace == "agent-debug"); .kind == "ServiceAccount" or .kind == "Secret");
    "The reader must live in its own restricted namespace, apart from the sandbox.") and
  check(
    $sandbox_role.rules == [
      {apiGroups: [""], resources: ["pods"], verbs: ["create", "delete", "get", "list", "watch"]},
      {apiGroups: [""], resources: ["pods/log"], verbs: ["get"]}
    ] and
    $sandbox_binding.roleRef == {apiGroup: "rbac.authorization.k8s.io", kind: "Role", name: $sandbox_role.metadata.name} and
    $sandbox_binding.subjects == $subjects;
    "In the sandbox, the reader may only create, read and delete pods and read their logs.") and
  check(
    ($sandbox | restricted) and
    $sandbox_default.automountServiceAccountToken == false and
    $sandbox_quota.spec.hard.pods != null;
    "Sandbox pods must be restricted, tokenless and limited by a quota.") and
  check(
    $sandbox_policy.spec == {
      podSelector: {}, policyTypes: ["Ingress", "Egress"],
      egress: [{to: [{ipBlock: {cidr: "10.244.0.0/16"}}]}]
    };
    "Sandbox pods must accept no inbound traffic and reach only the pod network.") and
  check(
    $sandbox_images.spec.matchConstraints.namespaceSelector == {matchLabels: {"kubernetes.io/metadata.name": "agent-sandbox"}} and
    $sandbox_images.spec.failurePolicy == "Fail" and
    $sandbox_images_binding.spec == {policyName: $sandbox_images.metadata.name, validationActions: ["Deny"]};
    "Sandbox pods must be limited to allowed images.")
' > /dev/null
