resource "kubernetes_namespace_v1" "agent_debug" {
  metadata {
    name = "agent-debug"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

resource "kubernetes_service_account_v1" "reader" {
  metadata {
    name      = "agent-debug-reader"
    namespace = kubernetes_namespace_v1.agent_debug.metadata[0].name
  }

  automount_service_account_token = false
}

resource "kubernetes_cluster_role_v1" "reader" {
  metadata {
    name = "agent-debug-reader"
  }

  rule {
    api_groups = [""]
    resources = [
      "pods", "events", "services", "endpoints", "configmaps",
      "nodes", "namespaces", "persistentvolumes", "persistentvolumeclaims",
      "replicationcontrollers", "resourcequotas", "limitranges"
    ]
    verbs = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets", "statefulsets", "daemonsets", "controllerrevisions"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses", "ingressclasses", "networkpolicies"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["discovery.k8s.io"]
    resources  = ["endpointslices"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["events.k8s.io"]
    resources  = ["events"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses", "csidrivers", "csinodes", "csistoragecapacities", "volumeattachments"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["policy"]
    resources  = ["poddisruptionbudgets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["metrics.k8s.io"]
    resources  = ["pods", "nodes"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["applications", "applicationsets", "appprojects"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["cert-manager.io"]
    resources  = ["certificates", "certificaterequests", "issuers", "clusterissuers"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["acme.cert-manager.io"]
    resources  = ["orders", "challenges"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["metallb.io"]
    resources  = ["ipaddresspools", "l2advertisements", "bgpadvertisements", "bgppeers", "bfdprofiles", "servicel2statuses", "servicebgpstatuses"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["openebs.io"]
    resources  = ["diskpools"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["monitoring.coreos.com"]
    resources = [
      "prometheuses", "prometheusagents", "alertmanagers", "alertmanagerconfigs",
      "servicemonitors", "podmonitors", "probes", "prometheusrules",
      "scrapeconfigs", "thanosrulers"
    ]
    verbs = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "reader" {
  metadata {
    name = "agent-debug-reader"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.reader.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.reader.metadata[0].name
    namespace = kubernetes_service_account_v1.reader.metadata[0].namespace
  }
}
