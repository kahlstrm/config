# cilium-failures

```sh
nix develop .#talos --command just talos run cilium-failures
```

Failures during and after the [cilium-migration](../cilium-migration/README.md)
cutover.

1. **cutover-with-reboot**: patch the workers and the control plane, then
   reboot a worker while Talos installs Cilium and `upgrade-k8s` runs. If
   `upgrade-k8s` fails, the test records why, waits for the worker and runs it
   again. Then it recreates the pods left on Flannel's network. Asserts that
   every workload, prober and the local volume recover and that every pod has
   a CiliumEndpoint.
2. **converged**: every signal up, no policed prober reaches the external
   address.
3. **agent-removed**: patch the Cilium DaemonSet so its agent leaves the first
   worker, as a failed or evicted agent would. Records traffic and policy on
   that worker for 40 seconds and whether a new pod starts there; asserts that
   no policed prober reached the external address.
4. **agent-restored**: records whether `upgrade-k8s` brings the agent back
   (Talos applies server-side, so it keeps fields another manager added),
   then removes the affinity and waits for the agent.
5. **agent-killed**: `pkill -9 cilium-agent` on the worker every second for a
   minute through the [node shell](../../manifests/node-shell.yaml), while the
   kubelet keeps restarting it. Records the outages; asserts that no policed
   prober reached the external address.
6. **agent-recovers**: records how long until a new pod starts on the worker
   again (the kubelet backs off restarting the agent), then asserts every
   signal up and first-packet enforcement for fresh pods.
