# Router certificate renewal

This scenario applies the production `local-networking/modules/cert/router` module
to a disposable CHR and renews its HTTPS certificate the way Let's Encrypt does.
Run from `~/config/infra` on Linux with `/dev/kvm`:

```sh
nix develop .#chr-bootstrap --command just chr run cert-renewal
```

The test generates a private chain shaped like Let's Encrypt's: a trust anchor
(`Lab Root X1`), a cross-signed root (`Lab Root YR`), and intermediates
(`Lab YR1`, `Lab YR2`). Terraform receives the leaf, its key, and the
intermediate plus cross-sign as the issuer chain, as `acme_certificate` provides
them. No ACME server or Internet access is involved beyond provider downloads.

1. The router starts on a self-signed `www-ssl` certificate, and Terraform
   installs the first leaf without TLS verification.
2. The provider switches to verifying the router against the trust anchor only,
   as production does after commissioning, and a plan must be empty.
3. A renewal with the same key and a new intermediate is applied.
4. A renewal with a new key is applied.

After each apply, the follow-up plan must be empty, and the router must serve
the expected leaf with a chain that verifies against the trust anchor, both
before and after restarting `www-ssl`. The restart catches a chain the service
only holds in memory.

Plans, logs, the trust anchor and Terraform state stay under
`$XDG_STATE_HOME/chr/cert-renewal/<run>`.
