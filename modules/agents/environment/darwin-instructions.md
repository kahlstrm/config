# macOS services

This dedicated Mac has no VM isolation: agents share the configured user's files
and login keychain. The manifest uses the same paths and deployment policy as
the Linux environment. `agent-deploy` queues the root launchd worker; inspect
`/nix/var/nix/profiles/agent-deploy/status.json` and `/var/log/agent-deploy.log`
after reconnecting. Do not deploy local commits or use personal GitHub credentials.

T3 and fork sync run in the user's login session. FileVault can require operator
unlock after reboot; never reboot without an explicit request. T3 logs are in
`~/Library/Logs/t3.log`.
