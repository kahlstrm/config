# Alert intake

An Amp plugin that turns Alertmanager webhooks into investigation threads on the
klusse runner (`infra/local-kubernetes/apps/amp-runner`), in the Homelab alerts &
incidents Space. Alertmanager sends it every critical alert through the
`amp-investigation` route (`platform/observability/alertmanagerconfig-amp-investigation.yaml`).

- **Auth:** Alertmanager sends `Authorization: Bearer <token>`. The plugin
  compares it with the `ALERT_WEBHOOK_TOKEN` project secret and drops anything
  else without retrying.
- **Dedup:** one thread per Alertmanager group (`groupKey`). Redelivered events
  are skipped; repeats of a group are appended to its thread until the group has
  been quiet for 7 days or the thread is archived.
- **Threads:** started with the `create_thread` tool on runner `klusse`, titled
  `<alertname> · <namespace> · <date>`. Threads that tool starts join the
  Space of the thread that loads the plugin; threads from the plugin API's
  `createThread` don't.

## Loading it

Exactly one thread owns the webhook: the intake thread, an orb thread in this
project that is in the Space. It is not in `.amp/plugins/`, so other threads
don't load it. In the intake thread:

```sh
mkdir -p ~/.config/amp/plugins
cp tools/alert-intake/alert-intake.ts ~/.config/amp/plugins/
```

Then load `~/.config/amp/plugins/alert-intake.ts` with `amp.load_plugin`, and
reload it the same way after changing it. Keep the intake thread unarchived:
archiving it turns the webhook URL into a 404 until the thread is restored.

The webhook URL is written to `alert-intake/webhook-url` under the plugin cache
directory, readable only by the orb user. It and the token go into the
`local-kubernetes` Secret Manager secret as `amp_alert_webhook_url` and
`amp_alert_webhook_token`, where `platform/observability/alertmanager-amp.yaml`
reads them. Never paste either into a thread.

## Tests

```sh
bun test tools/alert-intake
```

The flake check `alert-intake` runs the same tests in CI.
