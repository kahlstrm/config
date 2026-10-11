resource "kubernetes_service_account_v1" "issuer" {
  metadata {
    name      = "agent-debug-issuer"
    namespace = kubernetes_namespace_v1.agent_debug.metadata[0].name
  }

  automount_service_account_token = false
}

resource "kubernetes_role_v1" "issuer" {
  metadata {
    name      = "agent-debug-issuer"
    namespace = kubernetes_namespace_v1.agent_debug.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["serviceaccounts/token"]
    resource_names = [kubernetes_service_account_v1.reader.metadata[0].name]
    verbs          = ["create"]
  }
}

resource "kubernetes_role_binding_v1" "issuer" {
  metadata {
    name      = "agent-debug-issuer"
    namespace = kubernetes_namespace_v1.agent_debug.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.issuer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.issuer.metadata[0].name
    namespace = kubernetes_service_account_v1.issuer.metadata[0].namespace
  }
}
