resource "kubernetes_namespace" "external_dns" {
  depends_on = [talos_cluster_kubeconfig.this]

  metadata {
    name = "external-dns"
  }
}

resource "kubernetes_secret" "mikrotik_credentials" {
  depends_on = [kubernetes_namespace.external_dns]

  metadata {
    name      = "mikrotik-credentials"
    namespace = "external-dns"
  }

  data = {
    MIKROTIK_BASEURL         = "https://${data.terraform_remote_state.networking.outputs.kuberack_domain}"
    MIKROTIK_USERNAME        = data.terraform_remote_state.networking.outputs.external_dns_username
    MIKROTIK_PASSWORD        = local.config["external_dns_password"]
    MIKROTIK_SKIP_TLS_VERIFY = "false"
  }
}

resource "kubernetes_secret" "mikrotik_credentials_stationary" {
  depends_on = [kubernetes_namespace.external_dns]

  metadata {
    name      = "mikrotik-credentials-stationary"
    namespace = "external-dns"
  }

  data = {
    MIKROTIK_BASEURL         = "https://${data.terraform_remote_state.networking.outputs.stationary_domain}"
    MIKROTIK_USERNAME        = data.terraform_remote_state.networking.outputs.external_dns_username
    MIKROTIK_PASSWORD        = local.config["external_dns_password"]
    MIKROTIK_SKIP_TLS_VERIFY = "false"
  }
}

resource "kubernetes_namespace" "monitoring" {
  depends_on = [talos_cluster_kubeconfig.this]

  metadata {
    name = "monitoring"
  }
}

resource "kubernetes_secret" "mktxp_config" {
  depends_on = [kubernetes_namespace.monitoring]

  metadata {
    name      = "mktxp-config"
    namespace = "monitoring"
  }

  data = {
    "mktxp.conf" = <<-EOT
      [kuberack]
      hostname = ${data.terraform_remote_state.networking.outputs.kuberack_domain}
      port = 8729
      username = ${local.config["mktxp"]["username"]}
      password = ${local.config["mktxp"]["kuberack_rb5009_password"]}
      use_ssl = True

      [stationary]
      hostname = ${data.terraform_remote_state.networking.outputs.stationary_domain}
      port = 8729
      username = ${local.config["mktxp"]["username"]}
      password = ${local.config["mktxp"]["stationary_rb5009_password"]}
      use_ssl = True
      # RB5009UGS doesn't have PoE
      poe = False
    EOT
  }
}

resource "kubernetes_secret" "alertmanager_telegram" {
  depends_on = [kubernetes_namespace.monitoring]

  metadata {
    name      = "alertmanager-telegram"
    namespace = "monitoring"
  }

  data = {
    bot_token = local.config["alertmanager_telegram"]["bot_token"]
    chat_id   = local.config["alertmanager_telegram"]["chat_id"]
  }
}

resource "kubernetes_secret" "grafana_admin" {
  depends_on = [kubernetes_namespace.monitoring]

  metadata {
    name      = "grafana-admin"
    namespace = "monitoring"
  }

  data = {
    admin-user     = "admin"
    admin-password = local.config["grafana_admin_password"]
  }
}

resource "kubernetes_namespace" "cert_manager" {
  depends_on = [talos_cluster_kubeconfig.this]

  metadata {
    name = "cert-manager"
  }
}

resource "kubernetes_secret" "cloudflare_api_token_cert_manager" {
  depends_on = [kubernetes_namespace.cert_manager]

  metadata {
    name      = "cloudflare-api-token"
    namespace = "cert-manager"
  }

  data = {
    api-token = local.config["cf_dns_api_token"]
  }
}

ephemeral "random_password" "minio_root" {
  length  = 32
  special = false
}

resource "kubernetes_namespace" "minio" {
  depends_on = [talos_cluster_kubeconfig.this]

  metadata {
    name = "minio"
  }
}

resource "kubernetes_secret" "minio_env_configuration" {
  depends_on = [kubernetes_namespace.minio]

  metadata {
    name      = "minio-env-configuration"
    namespace = "minio"
  }

  data_wo_revision = 1
  data_wo = {
    "config.env" = <<-EOT
      export MINIO_ROOT_USER=admin
      export MINIO_ROOT_PASSWORD=${ephemeral.random_password.minio_root.result}
      export MINIO_PROMETHEUS_AUTH_TYPE=public
    EOT
  }
}

ephemeral "random_password" "minio_loki" {
  length  = 32
  special = false
}

locals {
  minio_loki_password_revision = 1
}

resource "kubernetes_secret" "minio_loki_user" {
  depends_on = [kubernetes_namespace.minio]

  metadata {
    name      = "minio-loki-user"
    namespace = "minio"
  }

  data_wo_revision = local.minio_loki_password_revision
  data_wo = {
    CONSOLE_ACCESS_KEY = "loki"
    CONSOLE_SECRET_KEY = ephemeral.random_password.minio_loki.result
  }
}

resource "kubernetes_namespace" "loki" {
  depends_on = [talos_cluster_kubeconfig.this]

  metadata {
    name = "loki"
  }
}

resource "kubernetes_secret" "loki_s3_credentials" {
  depends_on = [kubernetes_namespace.loki]

  metadata {
    name      = "loki-s3-credentials"
    namespace = "loki"
  }

  data_wo_revision = local.minio_loki_password_revision
  data_wo = {
    AWS_ACCESS_KEY_ID     = "loki"
    AWS_SECRET_ACCESS_KEY = ephemeral.random_password.minio_loki.result
    AWS_ENDPOINT_URL      = "minio.minio.svc:80"
    AWS_REGION            = "us-east-1"
    AWS_S3_INSECURE       = "true"
  }
}

ephemeral "random_password" "harbor_admin" {
  length  = 32
  special = true
}

resource "kubernetes_namespace" "harbor" {
  depends_on = [talos_cluster_kubeconfig.this]

  metadata {
    name = "harbor"
  }
}

resource "kubernetes_secret" "harbor_admin" {
  depends_on = [kubernetes_namespace.harbor]

  metadata {
    name      = "harbor-admin-password"
    namespace = "harbor"
  }

  data_wo_revision = 1
  data_wo = {
    HARBOR_ADMIN_PASSWORD = ephemeral.random_password.harbor_admin.result
  }
}

resource "kubernetes_namespace" "opencode" {
  depends_on = [talos_cluster_kubeconfig.this]

  metadata {
    name = "opencode"
  }
}

resource "kubernetes_secret" "opencode_credentials" {
  depends_on = [kubernetes_namespace.opencode]

  metadata {
    name      = "opencode-credentials"
    namespace = "opencode"
  }

  data = {
    OPENCODE_SERVER_PASSWORD = local.config["opencode"]["server_password"]
  }
}

resource "kubernetes_namespace" "docsight" {
  metadata {
    name = "docsight"
  }
}

ephemeral "random_password" "docsight_admin" {
  length  = 48
  special = false
}

ephemeral "random_password" "docsight_scrape" {
  length  = 64
  special = false
}

resource "kubernetes_secret_v1" "docsight_credentials" {
  depends_on = [kubernetes_namespace.docsight]
  metadata {
    name      = "docsight-credentials"
    namespace = kubernetes_namespace.docsight.metadata[0].name
  }
  # Increment to rotate both credentials, then restart DOCSight to rerun bootstrap.
  data_wo_revision = 1
  data_wo = {
    ADMIN_PASSWORD        = ephemeral.random_password.docsight_admin.result
    DOCSIGHT_SCRAPE_TOKEN = "dsk_${ephemeral.random_password.docsight_scrape.result}"
  }
}

resource "kubernetes_secret_v1" "docsight_modem_credentials" {
  metadata {
    name      = "docsight-modem-credentials"
    namespace = kubernetes_namespace.docsight.metadata[0].name
  }
  data = {
    MODEM_USER     = local.config["cable_modem"]["username"]
    MODEM_PASSWORD = local.config["cable_modem"]["password"]
  }
}
