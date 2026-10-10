module "agent_debug" {
  source     = "./modules/agent-debug"
  depends_on = [talos_cluster_kubeconfig.this]
}
