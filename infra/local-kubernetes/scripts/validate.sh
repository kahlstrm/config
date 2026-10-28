#!/usr/bin/env bash
# Render every kustomization and validate it, with the manifests Talos applies,
# against Kubernetes and CRD schemas.
set -euo pipefail

root=$(dirname "$0")/..
kubernetes_version=${KUBERNETES_VERSION:-1.34.1}
crd_schemas='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
# The default standalone schemas omit some built-in kinds, such as
# CustomResourceDefinition; the referencing schemas of the same release cover them.
kubernetes_schemas='https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/{{.NormalizedKubernetesVersion}}/{{.ResourceKind}}{{.KindSuffix}}.json'

# SOPS metadata isn't part of the Secret schema; Flux strips it when decrypting.
validate() {
  yq 'del(.sops)' "$@" | kubeconform -strict -summary -kubernetes-version "$kubernetes_version" \
    -schema-location default -schema-location "$crd_schemas" -schema-location "$kubernetes_schemas"
}

find "$root" -name kustomization.yaml -exec dirname {} \; | sort | while read -r directory; do
  echo "${directory#"$root"/}"
  kustomize build "$directory" | validate
done

echo local-talos/manifests
validate "$root"/../local-talos/manifests/*.yaml
