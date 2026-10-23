# Router certificate renewal

This scenario applies the production `local-networking/modules/cert/router` module
to a disposable CHR and renews its HTTPS certificate the way Let's Encrypt does.
Run from `~/config/infra` on Linux with `/dev/kvm`:

```sh
nix develop .#chr-bootstrap --command just chr run cert-renewal
```

The test generates a private chain shaped like Let's Encrypt's: a trust anchor
(`Lab Root X1`), a cross-signed root (`Lab Root YR`), and intermediates
(`Lab YR1`, `Lab YR2`, `Lab YR3`). Leaves carry a key-derived subject key
identifier, as Let's Encrypt's do. Terraform receives the leaf, its key, and the
intermediate plus cross-sign as the issuer chain, as `acme_certificate` provides
them, and YR1, YR2 and the cross-sign as the pinned chain. No ACME server or
Internet access is involved beyond provider downloads.

1. The router starts on a self-signed `www-ssl` certificate, and Terraform
   installs the first leaf without TLS verification.
2. The provider switches to verifying the router against the trust anchor only,
   as production does after commissioning, and a plan must be empty.
3. A certificate with a new key from a new intermediate is applied.
4. A certificate with a new key from the same intermediate is applied.
5. A certificate from the unpinned YR3 must fail the apply and leave the router
   serving the previous certificate.
6. An expired certificate is applied, standing in for one that ran out because
   nobody applied in time. The verifying plan must then fail with
   `certificate has expired`.
7. A new certificate is applied without TLS verification, as the operator would
   with `TF_VAR_ALLOW_INSECURE=true`, and a verifying plan must be empty again.

After each successful apply of a valid certificate, the router must serve the expected leaf with a chain that
verifies against the trust anchor in every one of many concurrent handshakes,
both before and after restarting `www-ssl`, and the follow-up plan must be
empty. `www-ssl` hands connections to worker processes that each keep the
certificate they started with, so a single handshake can miss a stale worker.

Renewals that keep the key are not supported: `www-ssl` workers find their leaf
by subject key identifier, and while the previous leaf exists they serve it with
the new chain. `modules/cert` issues every certificate with a new key.

Plans, logs, the trust anchor and Terraform state stay under
`$XDG_STATE_HOME/chr/cert-renewal/<run>`.
