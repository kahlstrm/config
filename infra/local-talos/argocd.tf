resource "helm_release" "argocd" {
  depends_on = [talos_cluster_kubeconfig.this]

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "9.0.5"
  namespace        = "argocd"
  create_namespace = true
  atomic           = true

  values = [
    yamlencode({
      server = {
        service = {
          type = "ClusterIP"
        }
      }
      configs = {
        params = {
          "server.insecure" = true
        }
      }
    })
  ]
}

# Marker resource that all helm releases depend into
resource "null_resource" "helm_charts_ready" {
  depends_on = [helm_release.argocd]
}

resource "kubernetes_manifest" "argocd_bootstrap" {
  depends_on = [null_resource.helm_charts_ready]

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "bootstrap"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/kahlstrm/config.git"
        targetRevision = "main"
        path           = "infra/local-kubernetes/apps"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true"
        ]
      }
    }
  }
}

resource "kubernetes_manifest" "argocd_bootstrap_talos" {
  depends_on = [null_resource.helm_charts_ready]

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "bootstrap-talos"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/kahlstrm/config.git"
        targetRevision = "main"
        path           = "infra/local-kubernetes/apps-talos"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true"
        ]
      }
    }
  }
}

data "kubernetes_secret" "argocd_initial_admin_secret" {
  depends_on = [null_resource.helm_charts_ready]

  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = "argocd"
  }
}
