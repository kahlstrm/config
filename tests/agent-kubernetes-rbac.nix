{ pkgs }:
pkgs.runCommand "agent-kubernetes-rbac"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.yq-go
    ];
  }
  ''
    bash ${./agent-kubernetes-rbac.sh} ${../infra/local-kubernetes/manifests/agent-debug} ${../infra/local-kubernetes/apps/agent-debug.yaml}
    touch "$out"
  ''
