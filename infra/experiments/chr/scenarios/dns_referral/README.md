# RouterOS DNS referral reproduction

This scenario checks whether caching root NS records changes an unrelated
negative AAAA response into a referral-shaped response: no answers, root NS
records in the authority section, and no SOA record.

Run from `~/config/infra` on Linux with `/dev/kvm` and internet access:

```sh
nix develop .#chr-dns --command just chr run dns-referral
```

The runner starts an isolated CHR VM if needed. To compare RouterOS versions,
stop the current VM first, then use `just chr --version VERSION run dns-referral`
inside `nix develop .#chr-dns`.

The scenario disables DHCP-provided DNS and DoH, uses `1.1.1.1` as the upstream,
flushes the router's DNS cache, and sends three queries through localhost port 1053:

1. `s3.eu-west-1.amazonaws.com AAAA`
2. `. NS`
3. `s3.eu-west-1.amazonaws.com AAAA`

The hostname must return NOERROR with no AAAA answers. If its public DNS changes,
choose another hostname with A records and no AAAA records in the scenario's
`HOST` constant. Positive answers and DNS failures abort the experiment.

Raw replies, router version/settings, and a summary are saved under
`$XDG_STATE_HOME/chr/<version>/results/dns-referral/<timestamp>` (default state
root: `~/.local/state/chr`). The summary reports whether the response changed;
both reproduced and fixed behavior are valid experiment results.

The scenario removes temporary port forwards and flushes the DNS cache on exit.
DNS settings remain on the lab VM; use `just chr fresh` before unrelated scenarios
if you need a clean router.

CI runs the response parser tests through the existing CHR test discovery.
The live experiment runs manually because it depends on public DNS and measures
RouterOS behavior rather than asserting that a particular version is fixed.
