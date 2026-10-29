# Runs reclaim.mjs and dispatch.mjs against a k3s API server, as the service
# accounts and with the RECLAIM_DAYS the rendered manifests give each namespace.
# KubeVirt only needs its CRDs: no VM runs, so a VirtualMachineInstance object
# stands for a running orb.
{ pkgs }:
let
  namespaces = {
    amp-orbs-kubevirt = "kubevirt";
    amp-orbs-katalyst = "workspace";
  };
  rendered =
    pkgs.runCommand "amp-orbs-rendered"
      {
        nativeBuildInputs = [
          pkgs.kustomize
          pkgs.yq-go
        ];
      }
      ''
        mkdir $out
        for overlay in kubevirt workspace; do
          kustomize build ${./.}/$overlay >all.yaml
          yq 'select(.kind == ("Namespace", "ServiceAccount", "Role", "RoleBinding"))' all.yaml >$out/$overlay.yaml
          yq 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == "RECLAIM_DAYS") | .value' all.yaml >$out/$overlay.days
        done
      '';
  crd = kind: plural: {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    metadata.name = "${plural}.kubevirt.io";
    spec = {
      group = "kubevirt.io";
      names = { inherit kind plural; };
      scope = "Namespaced";
      versions = [
        {
          name = "v1";
          served = true;
          storage = true;
          schema.openAPIV3Schema = {
            type = "object";
            x-kubernetes-preserve-unknown-fields = true;
          };
        }
      ];
    };
  };
  crds = pkgs.writeText "kubevirt-crds.json" (
    builtins.toJSON {
      apiVersion = "v1";
      kind = "List";
      items = [
        (crd "VirtualMachine" "virtualmachines")
        (crd "VirtualMachineInstance" "virtualmachineinstances")
      ];
    }
  );
  # Runs a script as the given service account the way its pod would.
  env = ''
    set -eu
    ns=$1
    export KUBERNETES_SERVICE_HOST=127.0.0.1 KUBERNETES_SERVICE_PORT=6443
    export NODE_EXTRA_CA_CERTS=/var/lib/rancher/k3s/server/tls/server-ca.crt
  '';
  reclaim = pkgs.writeShellScript "reclaim" ''
    ${env}
    sa=/var/run/secrets/kubernetes.io/serviceaccount
    mkdir -p $sa
    printf %s "$ns" >$sa/namespace
    kubectl -n "$ns" create token amp-orb-reclaim >$sa/token
    case $ns in
    ${pkgs.lib.concatStrings (
      pkgs.lib.mapAttrsToList (
        ns: overlay: "  ${ns}) RECLAIM_DAYS=$(cat ${rendered}/${overlay}.days) ;;\n"
      ) namespaces
    )}
    esac
    export RECLAIM_DAYS
    exec ${pkgs.nodejs}/bin/node ${./kubevirt/scripts/reclaim.mjs}
  '';
  dispatch = pkgs.writeShellScript "dispatch" ''
    ${env}
    export KUBE_API=https://127.0.0.1:6443 KUBE_NAMESPACE=$ns ORB_OPERATION=$2 ORB_ID=$3
    export KUBE_TOKEN=$(kubectl -n "$ns" create token amp-orb-provider)
    export ORB_TOKEN=token ORB_VM_IMAGE=orb@sha256:test
    exec ${pkgs.nodejs}/bin/node ${./kubevirt/scripts/dispatch.mjs}
  '';
in
{
  name = "amp-orbs";

  nodes.machine = {
    virtualisation.memorySize = 2048;
    services.k3s = {
      enable = true;
      role = "server";
      # Only the API server is needed: no pod runs.
      extraFlags = [
        "--disable coredns"
        "--disable local-storage"
        "--disable metrics-server"
        "--disable servicelb"
        "--disable traefik"
        "--disable-helm-controller"
        "--disable-network-policy"
      ];
    };
    environment.systemPackages = [ pkgs.kubectl ];
    environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
  };

  testScript = ''
    import json

    def kubectl(args, input=None):
        command = f"kubectl {args}"
        if input is not None:
            command = f"{command} <<'EOF'\n{json.dumps(input)}\nEOF"
        return machine.succeed(command)

    def annotations(ns, claim):
        return json.loads(kubectl(f"-n {ns} get pvc {claim} -o json"))["metadata"].get("annotations", {})

    def left(ns):
        names = kubectl(f"-n {ns} get pvc,virtualmachines.kubevirt.io,secrets -o name").split()
        return sorted(name.split("/")[1] for name in names)

    now = int(machine.succeed("date +%s"))
    def days_ago(days):
        return machine.succeed(f"date -u -d @{now - days * 86400} +%Y-%m-%dT%H:%M:%SZ").strip()

    def orb(id, kind, name=None, paused=None, extra=None):
        labels = {"app.kubernetes.io/name": "amp-orb", "amp.ampcode.com/orb-id": id}
        metadata = {"name": name or f"{id}-{kind.lower()}", "labels": labels}
        if paused is not None:
            metadata["annotations"] = {"amp.ampcode.com/paused-at": days_ago(paused)}
        api = "kubevirt.io/v1" if kind.startswith("Virtual") else "v1"
        return {"apiVersion": api, "kind": kind, "metadata": metadata, **(extra or {})}

    claim_spec = {"spec": {"accessModes": ["ReadWriteOnce"], "storageClassName": "orb-storage",
                           "resources": {"requests": {"storage": "1Gi"}}}}
    def claim(id, disk, paused=None):
        return orb(id, "PersistentVolumeClaim", f"{id}-{disk}", paused, claim_spec)
    def paused_orb(id, days):
        return [claim(id, "state", days), claim(id, "swap"), orb(id, "VirtualMachine", f"{id}-vm", extra={"spec": {}}),
                orb(id, "Secret", f"{id}-env", extra={"stringData": {"ORB_TOKEN": "x"}})]

    machine.wait_for_unit("k3s.service")
    machine.wait_until_succeeds("kubectl get serviceaccount default")
    kubectl("apply -f ${crds}")
    machine.wait_until_succeeds("kubectl get virtualmachines.kubevirt.io")
    kubectl("apply -f ${rendered}/kubevirt.yaml -f ${rendered}/workspace.yaml")

    for ns in ["amp-orbs-kubevirt", "amp-orbs-katalyst"]:
        items = [
            # Running: a stale pause time and its home disk must not matter.
            *paused_orb("amp-running", 30), claim("amp-running", "home"),
            orb("amp-running", "VirtualMachineInstance", "amp-running-vm", extra={"spec": {}}),
            *paused_orb("amp-old15", 15), *paused_orb("amp-old10", 10), *paused_orb("amp-old5", 5),
            claim("amp-unstamped", "state"), claim("amp-unstamped", "swap"),
            claim("amp-legacy", "home"),
            {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "unrelated"}, **claim_spec},
        ]
        kubectl(f"-n {ns} apply -f -", {"apiVersion": "v1", "kind": "List", "items": items})

    def kept(*ids):
        names = {"amp-running": ["env", "home", "state", "swap", "vm"], "amp-unstamped": ["state", "swap"]}
        return sorted([f"{id}-{n}" for id in ["amp-running", "amp-unstamped"] for n in names[id]]
                      + [f"{id}-{n}" for id in ids for n in ["env", "state", "swap", "vm"]] + ["unrelated"])

    with subtest("reclaims orbs paused longer than each namespace's RECLAIM_DAYS"):
        machine.succeed("${reclaim} amp-orbs-kubevirt")
        assert left("amp-orbs-kubevirt") == kept("amp-old10", "amp-old5"), left("amp-orbs-kubevirt")
        machine.succeed("${reclaim} amp-orbs-katalyst")
        assert left("amp-orbs-katalyst") == kept("amp-old5"), left("amp-orbs-katalyst")

    with subtest("starts counting for a stopped orb without a pause time"):
        assert days_ago(0)[:10] == annotations("amp-orbs-katalyst", "amp-unstamped-state")["amp.ampcode.com/paused-at"][:10]

    with subtest("a second run changes nothing"):
        output = machine.succeed("${reclaim} amp-orbs-katalyst")
        assert output == "", output
        assert left("amp-orbs-katalyst") == kept("amp-old5")

    with subtest("dispatch records the pause and clears it on spawn"):
        machine.succeed("${dispatch} amp-orbs-katalyst pause amp-old5")
        paused = annotations("amp-orbs-katalyst", "amp-old5-state")["amp.ampcode.com/paused-at"]
        assert paused[:10] == days_ago(0)[:10], paused
        # No VM runs here, so spawn waits for one until it is stopped.
        machine.succeed("timeout 20 ${dispatch} amp-orbs-katalyst spawn amp-old5 || [ $? = 124 ]")
        spawned = annotations("amp-orbs-katalyst", "amp-old5-state")
        assert "amp.ampcode.com/paused-at" not in spawned, spawned
        assert spawned["amp.ampcode.com/booted-image"] == "orb@sha256:test", spawned
  '';
}
