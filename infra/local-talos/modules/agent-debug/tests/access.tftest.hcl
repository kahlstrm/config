mock_provider "kubernetes" {}

run "read_only_debugging" {
  command = plan

  assert {
    condition = alltrue([
      for rule in kubernetes_cluster_role_v1.reader.rule :
      length(setsubtract(toset(rule.verbs), toset(["get", "list", "watch"]))) == 0 &&
      !contains(rule.api_groups, "*") &&
      length(coalesce(rule.non_resource_urls, [])) == 0 &&
      length(setintersection(toset(rule.resources), toset([
        "*", "secrets", "pods/exec", "pods/attach", "pods/portforward",
        "pods/ephemeralcontainers", "pods/proxy", "services/proxy", "nodes/proxy",
        "serviceaccounts/token", "certificatesigningrequests"
      ]))) == 0
    ])
    error_message = "The debugging role must exclude mutations, wildcards, credentials and interactive/proxy access."
  }

  assert {
    condition = alltrue([
      for access in [
        { group = "", resource = "pods", verb = "list" },
        { group = "", resource = "pods/log", verb = "get" },
        { group = "", resource = "events", verb = "watch" },
        { group = "", resource = "nodes", verb = "get" },
        { group = "", resource = "persistentvolumeclaims", verb = "get" },
        { group = "apps", resource = "deployments", verb = "get" },
        { group = "discovery.k8s.io", resource = "endpointslices", verb = "list" },
        { group = "metrics.k8s.io", resource = "pods", verb = "list" },
        { group = "metrics.k8s.io", resource = "nodes", verb = "list" },
        { group = "argoproj.io", resource = "applications", verb = "get" },
        { group = "cert-manager.io", resource = "certificates", verb = "get" },
        { group = "metallb.io", resource = "ipaddresspools", verb = "get" },
        { group = "openebs.io", resource = "diskpools", verb = "get" },
        { group = "monitoring.coreos.com", resource = "prometheusrules", verb = "get" }
        ] : anytrue([
          for rule in kubernetes_cluster_role_v1.reader.rule :
          contains(rule.api_groups, access.group) &&
          contains(rule.resources, access.resource) && contains(rule.verbs, access.verb)
      ])
    ])
    error_message = "The role must support workload, log, event, node, storage, networking, metric and controller diagnostics."
  }

  assert {
    condition = (
      kubernetes_cluster_role_binding_v1.reader.role_ref[0].kind == "ClusterRole" &&
      kubernetes_cluster_role_binding_v1.reader.role_ref[0].name == kubernetes_cluster_role_v1.reader.metadata[0].name &&
      length(kubernetes_cluster_role_binding_v1.reader.subject) == 1 &&
      kubernetes_cluster_role_binding_v1.reader.subject[0].kind == "ServiceAccount" &&
      kubernetes_cluster_role_binding_v1.reader.subject[0].name == kubernetes_service_account_v1.reader.metadata[0].name &&
      kubernetes_cluster_role_binding_v1.reader.subject[0].namespace == kubernetes_namespace_v1.agent_debug.metadata[0].name &&
      !kubernetes_service_account_v1.reader.automount_service_account_token
    )
    error_message = "Bind only the dedicated service account, with automatic token mounting disabled."
  }
}
