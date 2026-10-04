# CHR lab

Requires Linux and `/dev/kvm`. Run the two-router bootstrap/adoption test:

```sh
nix develop .#chr-bootstrap --command just chr run bootstrap
```

For an interactive router, enter `nix develop .#chr`, then use `just chr start`,
`ssh`, `stop`, or `fresh`. `fresh` archives the old disk. Select another version
with `just chr --version 7.23.5 start`; stop the old VM before reusing its SSH port.

State and credentials live under `$XDG_STATE_HOME/chr` (default `~/.local/state/chr`);
use `--state PATH` to override. Forwarded ports bind only to localhost.
Nix pins and caches the pristine image via `image.nix`; other versions use a local
download cache. Keep `images/nix-roots/` while retaining disks backed by Nix images.

See the [bootstrap scenario](scenarios/bootstrap/README.md) for coverage and CI details.
Use `nix develop .#chr-dns --command just chr run dns-referral` for the
[DNS referral reproduction](scenarios/dns_referral/README.md).
Add experiments under `scenarios/<name>/__init__.py` with an `experiment(lab)` entry point.
