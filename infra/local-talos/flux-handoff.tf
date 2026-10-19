# Flux adopts these resources; delete this file once applied.
removed {
  from = helm_release.openebs
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_storage_class_v1.local_nvme
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_namespace.metallb
  lifecycle {
    destroy = false
  }
}

removed {
  from = helm_release.metallb
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_manifest.metallb_ipaddresspool
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_manifest.metallb_l2advertisement
  lifecycle {
    destroy = false
  }
}

# Argo CD keeps running until Flux has adopted its apps; uninstall it then.
removed {
  from = helm_release.argocd
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_manifest.argocd_bootstrap
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_manifest.argocd_bootstrap_talos
  lifecycle {
    destroy = false
  }
}

# Delete the minio namespace once Flux has removed MinIO and Loki no longer uses S3.
removed {
  from = kubernetes_namespace.loki
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_namespace.minio
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_secret.minio_env_configuration
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_secret.minio_loki_user
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_secret.loki_s3_credentials
  lifecycle {
    destroy = false
  }
}
