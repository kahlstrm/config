# RouterOS DNS referral reproduction

This scenario checks whether caching root NS records changes an unrelated
negative AAAA response into a referral-shaped response: no answers, root NS
records in the authority section, and no SOA record.

Run from `~/config/infra` on Linux with `/dev/kvm` and internet access:

```sh
nix develop .#chr-dns --command just chr run dns-referral
```

Each run starts a disposable CHR VM with private state and kernel-assigned
localhost management and DNS ports. To compare RouterOS versions, use
`just chr --version VERSION run dns-referral` inside `nix develop .#chr-dns`.

Terratest imports the factory DHCP client into the scenario's Terraform fixture,
disables DHCP-provided DNS and DoH, enables remote DNS requests, and sets `1.1.1.1`
as the upstream. An empty follow-up plan verifies the configuration is stable.
The test then flushes the router's DNS cache and sends three queries:

1. `s3.eu-west-1.amazonaws.com AAAA`
2. `. NS`
3. `s3.eu-west-1.amazonaws.com AAAA`

The hostname must return NOERROR with no AAAA answers. If its public DNS changes,
choose another hostname with A records and no AAAA records in `TestDNSReferral`
in `integration_test.go`. Positive answers and DNS failures abort the experiment.

Raw replies, router version/settings, and a summary are saved under
`$XDG_STATE_HOME/chr/dns-referral/<run>` (default state
root: `~/.local/state/chr`). The summary reports whether the response changed;
both reproduced and fixed behavior are valid experiment results.

Cleanup removes temporary DNS forwards, flushes the cache, destroys the Terraform
fixture while management is reachable, and stops the VM, including after failed
assertions. State, disks and captures remain private for diagnosis.
The factory API service is retained during initial console setup so Terraform
can connect; it is forwarded only to localhost. Scenario DNS settings are owned
by Terraform rather than SSH commands.

CI runs the Go unit tests and this live scenario. The scenario depends on public
DNS and measures RouterOS behavior rather than asserting that a particular
version is fixed. Both reproduced and fixed behavior pass; failure to establish
the prerequisites, apply stable configuration, query DNS, or clean up fails.
