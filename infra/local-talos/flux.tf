module "flux_operator_bootstrap" {
  source     = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  version    = "0.9.0"
  depends_on = [talos_cluster_kubeconfig.this]

  revision = 1

  gitops_resources = {
    instance_yaml = file("${local.flux_system_path}/flux-instance.yaml")
    operator_chart = {
      version     = "0.61.0"
      values_yaml = file("${local.flux_system_path}/flux-operator-values.yaml")
    }
  }
}

locals {
  flux_system_path = "${path.module}/../local-kubernetes/clusters/${local.cluster_name}/flux-system"
}
