# Dead-man restore

This scenario tests the switch that `infra-apply apply local-networking` arms on each router a
local-networking plan touches (`modules/infra-apply/worker/routeros`), on one
disposable CHR over its REST API. Run from `~/config/infra` on Linux with `/dev/kvm`:

```sh
nix develop .#chr-bootstrap --command just chr run deadman
```

1. The switch saves a backup and schedules its load 45 seconds later; arming a
   second time is refused.
2. A change made after arming, standing in for an apply whose checks fail, is
   rolled back: the router loads the backup, reboots with its earlier identity
   and answers REST again. The leftover backup without its job reports the restore.
3. Arming again, changing the router and disarming keeps the change past the
   restore time and leaves neither the job nor the backup.

The health check needs the CHR's DHCP default route through QEMU's user network.
