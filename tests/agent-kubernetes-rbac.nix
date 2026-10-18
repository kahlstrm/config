{ pkgs }:
pkgs.runCommand "agent-kubernetes-rbac"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.yq-go
      pkgs.kustomize
    ];
  }
  ''
    bash ${./agent-kubernetes-rbac.sh} ${../infra/local-kubernetes/apps/agent-debug}
    touch "$out"
  ''
