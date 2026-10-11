mock_provider "kubernetes" {}

run "issuer_cannot_read_or_mint_other_identities" {
  command = plan

  assert {
    condition = (
      length(kubernetes_role_v1.issuer.rule) == 1 &&
      toset(kubernetes_role_v1.issuer.rule[0].api_groups) == toset([""]) &&
      toset(kubernetes_role_v1.issuer.rule[0].resources) == toset(["serviceaccounts/token"]) &&
      toset(kubernetes_role_v1.issuer.rule[0].resource_names) == toset(["agent-debug-reader"]) &&
      toset(kubernetes_role_v1.issuer.rule[0].verbs) == toset(["create"])
    )
    error_message = "The issuer may only request tokens for the dedicated reader, without Secret or workload access."
  }

  assert {
    condition = (
      kubernetes_role_v1.issuer.metadata[0].namespace == kubernetes_namespace_v1.agent_debug.metadata[0].name &&
      kubernetes_role_binding_v1.issuer.role_ref[0].kind == "Role" &&
      kubernetes_role_binding_v1.issuer.role_ref[0].name == kubernetes_role_v1.issuer.metadata[0].name &&
      length(kubernetes_role_binding_v1.issuer.subject) == 1 &&
      kubernetes_role_binding_v1.issuer.subject[0].kind == "ServiceAccount" &&
      kubernetes_role_binding_v1.issuer.subject[0].name == kubernetes_service_account_v1.issuer.metadata[0].name &&
      kubernetes_role_binding_v1.issuer.subject[0].namespace == kubernetes_namespace_v1.agent_debug.metadata[0].name &&
      !kubernetes_service_account_v1.issuer.automount_service_account_token
    )
    error_message = "Bind the issuer only within the debugging namespace and disable token mounting."
  }
}
