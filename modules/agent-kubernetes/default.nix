# Read-only cluster access for agents, active once the reader token is enrolled.
# Enroll from the repository root after the agent-debug Application syncs:
#   reader() { kubectl --context=admin@klusse --namespace=agent-debug get secret agent-debug-reader-token --output=go-template="{{$1 | base64decode}}"; }
#   reader '(index .data "ca.crt")' > secrets/agent-kubernetes-ca.crt
#   token=$(reader .data.token) && AGENIX_RULES=secrets/secrets.nix agenix --edit agent-kubernetes-token.age <<< "$token"
# base64decode fails on a missing value, so a failed fetch never encrypts an empty token.
# Commit both files and deploy. Re-enroll after rebuilding the cluster or recreating
# the token Secret; delete both files to revoke access from the agent environment.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  token = ../../secrets/agent-kubernetes-token.age;
  api = (import ../agents/vm/settings.nix).allowedServices.kubernetes-api;
  kubeconfig = "/etc/agent-kubernetes/config";
in
{
  config = lib.mkIf (builtins.pathExists token) {
    age.secrets.agent-kubernetes-token = {
      file = token;
      owner = "agent";
      mode = "0400";
    };
    environment.etc."agent-kubernetes/config".text = builtins.toJSON {
      apiVersion = "v1";
      kind = "Config";
      clusters = [
        {
          name = "klusse";
          cluster = {
            server = "https://${api.address}:${toString (builtins.head api.tcpPorts)}";
            certificate-authority = ../../secrets/agent-kubernetes-ca.crt;
          };
        }
      ];
      users = [
        {
          name = "agent-debug-reader";
          user.tokenFile = config.age.secrets.agent-kubernetes-token.path;
        }
      ];
      contexts = [
        {
          name = "agent-debug";
          context = {
            cluster = "klusse";
            user = "agent-debug-reader";
          };
        }
      ];
      current-context = "agent-debug";
    };
    environment.systemPackages = [ pkgs.kubectl ];
    environment.sessionVariables.KUBECONFIG = kubeconfig;
    systemd.services.t3code.environment.KUBECONFIG = kubeconfig;
    local.agentEnvironment.credentials.kubernetes = {
      inherit kubeconfig;
      access = "read-only cluster diagnostics through the kubernetes-api service; no Secrets, mutations, exec, attach, port-forward or proxy";
    };
  };
}
