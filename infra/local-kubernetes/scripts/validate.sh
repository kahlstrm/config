#!/usr/bin/env bash
# Render every kustomization and validate it against Kubernetes and CRD schemas.
set -euo pipefail

root=$(dirname "$0")/..
kubernetes_version=${KUBERNETES_VERSION:-1.34.1}
crd_schemas='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

find "$root" -name kustomization.yaml -exec dirname {} \; | sort | while read -r directory; do
  echo "${directory#"$root"/}"
  kustomize build "$directory" |
    kubeconform -strict -summary -kubernetes-version "$kubernetes_version" \
      -schema-location default -schema-location "$crd_schemas"
done
