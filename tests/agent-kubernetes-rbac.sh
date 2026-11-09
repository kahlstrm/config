set -euo pipefail

for manifests in "$@"; do
  kustomize build "$manifests"
  echo ---
done | yq --output-format=json '.' | jq -se '
  map(select(. != null)) as $all |
  def one($kind; $namespace; $name):
    [$all[] | select(.kind == $kind and (.metadata.namespace // "") == $namespace and .metadata.name == $name)] |
    if length == 1 then .[0] else error("Expected exactly one \($kind) \($namespace)/\($name).") end;
  def check($condition; $message): if $condition then true else error($message) end;

  one("Namespace"; ""; "agent-debug") as $reader_namespace |
  one("ServiceAccount"; "agent-debug"; "agent-debug-reader") as $reader |
  one("ClusterRole"; ""; "agent-debug-reader") as $role |
  one("ClusterRoleBinding"; ""; "agent-debug-reader") as $binding |
  one("ClusterRole"; ""; "agent-debug-pod-recycler") as $recycler |
  one("ClusterRoleBinding"; ""; "agent-debug-pod-recycler") as $recycler_binding |
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
  one("Namespace"; ""; "amp-runner") as $runner_namespace |
  one("ServiceAccount"; "amp-runner"; "alert-investigator") as $investigator |
  one("Deployment"; "amp-runner"; "amp-runner") as $runner |
  one("NetworkPolicy"; "amp-runner"; "amp-runner") as $runner_policy |
  [{kind: "ServiceAccount", name: "alert-investigator", namespace: "amp-runner"}] as $investigator_subjects |
  [$all[] | select(.kind == "RoleBinding" or .kind == "ClusterRoleBinding") |
    select(any(.subjects[]?; .name == "alert-investigator" and .namespace == "amp-runner"))] as $investigator_bindings |
  one("ServiceAccount"; "agent-debug"; "break-glass-reader") as $break_glass |
  one("Secret"; "agent-debug"; "break-glass-reader-token") as $break_glass_token |
  [$all[] | select(.kind == "RoleBinding" or .kind == "ClusterRoleBinding") |
    select(any(.subjects[]?; .name == "break-glass-reader" and .namespace == "agent-debug"))] as $break_glass_bindings |
  $runner.spec.template.spec as $runner_pod |
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
    $recycler.rules == [
      {apiGroups: [""], resources: ["pods"], verbs: ["delete"]},
      {apiGroups: [""], resources: ["pods/eviction"], verbs: ["create"]}
    ] and
    $recycler_binding.roleRef == {apiGroup: "rbac.authorization.k8s.io", kind: "ClusterRole", name: $recycler.metadata.name} and
    $recycler_binding.subjects == $subjects;
    "Outside the sandbox, the reader may only delete and evict pods, so their controllers recreate them.") and
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
      egress: [{to: [{namespaceSelector: {}}]}]
    };
    "Sandbox pods must accept no inbound traffic and reach only the pod network.") and
  check(
    ($investigator_bindings | map({kind, namespace: (.metadata.namespace // ""), role: .roleRef, subjects}) | sort_by(.kind)) == [
      {kind: "ClusterRoleBinding", namespace: "", role: {apiGroup: "rbac.authorization.k8s.io", kind: "ClusterRole", name: $role.metadata.name}, subjects: $investigator_subjects},
      {kind: "RoleBinding", namespace: "monitoring", role: {apiGroup: "rbac.authorization.k8s.io", kind: "Role", name: $monitoring_api.metadata.name}, subjects: $investigator_subjects}
    ] and
    $investigator.automountServiceAccountToken == false;
    "alert-investigator may only read, through the reader role and the GET-only monitoring proxy.") and
  check(
    ($break_glass_bindings | map({kind, role: .roleRef, subjects})) == [
      {kind: "ClusterRoleBinding", role: {apiGroup: "rbac.authorization.k8s.io", kind: "ClusterRole", name: $role.metadata.name},
       subjects: [{kind: "ServiceAccount", name: "break-glass-reader", namespace: "agent-debug"}]}
    ] and
    $break_glass.automountServiceAccountToken == false and
    $break_glass_token.type == "kubernetes.io/service-account-token" and
    $break_glass_token.metadata.annotations["kubernetes.io/service-account.name"] == "break-glass-reader";
    "The break-glass reader may only read, through the reader role.") and
  check(
    ($runner_namespace | restricted) and
    ([$all[] | select((.kind == "Role" or .kind == "RoleBinding") and .metadata.namespace == "amp-runner")] | length == 0);
    "Nothing in the runner namespace may grant reads of its Secrets.") and
  check(
    $runner.spec.replicas == 1 and $runner.spec.strategy.type == "Recreate" and
    $runner_pod.hostname == "klusse" and
    $runner_pod.serviceAccountName == "alert-investigator" and
    $runner_pod.nodeSelector["kubernetes.io/arch"] == "amd64" and
    all($runner_pod.containers[];
      (.image | test("@sha256:[0-9a-f]{64}$")) and
      .securityContext.readOnlyRootFilesystem == true and
      .securityContext.allowPrivilegeEscalation == false and
      (.args | index("klusse")));
    "One pinned, read-only runner pod registers as klusse with alert-investigator.") and
  check(
    $runner_policy.spec.podSelector == {} and
    ($runner_policy.spec.policyTypes | sort) == ["Egress", "Ingress"] and
    ($runner_policy.spec.ingress // [] | length == 0) and
    ($runner_policy.spec.egress | length > 0) and
    all($runner_policy.spec.egress[];
      (.to | length > 0) and (.ports | length > 0) and
      all(.to[];
        if .ipBlock then
          if (.ipBlock.cidr == "0.0.0.0/0") then
            (.ipBlock.except | contains(["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16"]))
          elif (.ipBlock.cidr == "::/0") then
            (.ipBlock.except | contains(["fc00::/7", "fe80::/10"]))
          else
            (.ipBlock.cidr | IN("10.10.10.10/32", "10.10.10.11/32", "10.10.10.12/32", "10.10.10.13/32"))
          end
        else
          . == {namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": "kube-system"}}, podSelector: {matchLabels: {"k8s-app": "kube-dns"}}}
        end) and
      (([.to[] | if .ipBlock then (if (.ipBlock.cidr | IN("0.0.0.0/0", "::/0")) then "internet" else "api" end) else "dns" end] | unique) as $kinds |
      ($kinds | length == 1) and
      ({internet: [{protocol: "TCP", port: 443}], api: [{protocol: "TCP", port: 6443}],
        dns: [{protocol: "TCP", port: 53}, {protocol: "UDP", port: 53}]}[$kinds[0]] == (.ports | sort_by(.protocol)))));
    "The runner accepts no inbound traffic and reaches only the cluster DNS, the Kubernetes API and HTTPS on the internet.") and
  check(
    $sandbox_images.spec.matchConstraints.namespaceSelector == {matchLabels: {"kubernetes.io/metadata.name": "agent-sandbox"}} and
    $sandbox_images.spec.failurePolicy == "Fail" and
    $sandbox_images_binding.spec == {policyName: $sandbox_images.metadata.name, validationActions: ["Deny"]};
    "Sandbox pods must be limited to allowed images.")
' > /dev/null
