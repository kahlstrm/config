# Agent debugging access

The `agent_debug` Terraform module creates the `agent-debug` namespace, the
`agent-debug-reader` ServiceAccount, and a ClusterRole and ClusterRoleBinding
with the same name. An operator reviews a normal `local-talos` plan and applies
it using the existing cluster provider. Agents do not apply this layer.

The binding grants read access across all namespaces to workloads, events,
ConfigMaps, networking and storage resources, nodes, pod logs and resource
metrics. Selected Argo CD, cert-manager, MetalLB, OpenEBS and Prometheus Operator
resources are also readable. Custom resources must exist in the cluster for
their queries to work; the role does not install controllers or CRDs.

The role grants no Secret access, mutations, exec, attach, port-forwarding,
ephemeral containers, proxy access or token issuance. Kubernetes RBAC grants
are additive: other bindings to this identity can expand its permissions.
The dedicated namespace uses restricted Pod Security admission, and the
ServiceAccount disables automatic token mounting. Interactive debugging
requires a separately reviewed namespace-scoped role.

Read access still exposes application data: logs and ConfigMaps can contain
credentials, and workload specifications can contain literal environment
values. Treat diagnostic output as private and redact it before sharing.

## Credentials

Use a short-lived TokenRequest token; do not create a ServiceAccount token
Secret or manage a token through Terraform. On the operator's trusted machine,
using an existing administrative context:

```sh
umask 077
kubectl --context <admin-context> -n agent-debug create token agent-debug-reader \
  --duration=1h > /secure/path/agent-debug.token
```

The API server determines the actual expiry. The operator securely provisions
the token and cluster CA to the VM outside the repository, with files readable
only by `agent`, and supplies a dedicated kubeconfig such as:

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: klusse
    cluster:
      server: https://10.10.10.11:6443
      certificate-authority: /home/agent/.kube/klusse-ca.crt
users:
  - name: agent-debug-reader
    user:
      tokenFile: /home/agent/.kube/agent-debug.token
contexts:
  - name: agent-debug
    context:
      cluster: klusse
      user: agent-debug-reader
      namespace: default
current-context: agent-debug
```

Save the kubeconfig as `/home/agent/.kube/agent-debug-config`. Replace the server
address if the cluster endpoint changes, and review the VM's Kubernetes API
network exception separately when needed. Keep TLS verification enabled.
Renew the token through the operator before it expires; the reader cannot mint
its own replacement. Do not provide the Talos administrative kubeconfig to the
VM or print credential files in diagnostic output.

## Verify access

Run from `infra` in the development shell, using the reader's credentials:

```sh
export KUBECONFIG=/home/agent/.kube/agent-debug-config
kubectl auth can-i list pods --all-namespaces
kubectl auth can-i get pods --subresource=log -n kube-system
kubectl auth can-i list nodes
kubectl auth can-i list nodes.metrics.k8s.io
kubectl auth can-i list applications.argoproj.io -n argocd
kubectl get nodes
kubectl get pods -A
kubectl get events -A --sort-by=.metadata.creationTimestamp
kubectl top nodes
```

The authorization checks above should return `yes`. Verify the following
return `no` (each denied check exits with status 1):

```sh
kubectl auth can-i list secrets --all-namespaces
kubectl auth can-i create pods --subresource=exec -n kube-system
kubectl auth can-i create pods --subresource=portforward -n monitoring
kubectl auth can-i patch pods --subresource=ephemeralcontainers -n default
kubectl auth can-i get nodes --subresource=proxy
kubectl auth can-i create serviceaccounts --subresource=token -n agent-debug
kubectl auth can-i patch deployments.apps -n default
```

The shared infrastructure workflow runs the module's mocked plan tests without
cluster credentials, alongside validation of the other Terraform layers.
Run the same checks locally from `infra`:

```sh
terraform -chdir=local-talos/modules/agent-debug init -backend=false -lockfile=readonly
terraform -chdir=local-talos/modules/agent-debug validate
terraform -chdir=local-talos/modules/agent-debug test
```

Kubernetes RBAC does not authorize Talos OS APIs. Talos diagnostics require
separately reviewed credentials and network access.
