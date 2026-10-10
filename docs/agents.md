# Coding agent environments

## Purpose

Agents get a persistent environment with shared tools, skills, workspaces, and
provider sign-ins. T3 provides the human interface. This keeps agent work separate
from the personal host without requiring repeated setup for each session.

Agents within an environment share credentials and are one trust domain. On
pannu, a dedicated VM isolates that domain from the host. Host-controlled network
rules restrict access to private services; exceptions are reviewed explicitly.
Human access uses the private network and T3 device pairing.

## Environment and hosting

The reusable environment lives in `modules/agents/environment/`; VM integration
lives in `modules/agents/vm/`. This lets another dedicated NixOS machine use the
same agent setup without depending on pannu or MicroVM.

`machines/agents.nix` defines the agent environment, while `machines/pannu.nix`
defines its hosting. Agents can update their environment without administering
the host. On a dedicated machine without VM isolation, the whole machine belongs
to the agents' trust domain.

## GitHub access

Agents use separate GitHub Apps to write forks and propose upstream PRs. They
cannot write or merge upstream, so operator review remains the approval boundary.
App installation permissions enforce this separation. The operator provisions
Apps, forks, secrets, and provider sign-ins; personal credentials stay outside.

Forks sync automatically to keep agent checkouts current without manual upkeep.
Sync preserves agent work and leaves conflicts for review. Fork Actions are
disabled to avoid duplicate workflow execution; upstream Actions validate PRs.

## Environment updates

Agents can deploy merged upstream `main` to their configured environment. This
allows routine updates after review without granting access to host deployment.
Deployment runs independently of the requesting session so service restarts do
not interrupt it.

VM updates cover the running environment; the operator retains control of the
boot image, resources, and network policy. Dedicated machines can update their
whole system. Successful updates persist across reboots, and failed activation
attempts rollback. An operator's new VM boot image takes precedence.

The VM owns a persistent Nix store so host image updates retain guest deployment
closures and build dependencies. Boot images supply missing store contents before
registration; replacing an image does not discard the guest's Nix state.

Nix manages the shared environment and skills. Provider CLIs use their native
updaters so they can follow provider releases independently. Persistent state and
backups contain credentials and must be protected accordingly.

See the [agent instructions](../modules/agents/environment/instructions.md) for
the working procedures and environment manifest.
