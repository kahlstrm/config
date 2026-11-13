# Secrets

`secrets.nix` maps encrypted files to host public keys and the offline recovery key.
The CLI is installed with the development packages. From this directory:

```sh
agenix -e headscale-oidc.age # edit
agenix -d headscale-oidc.age # view
agenix -r # after changing recipients
```

Create listed files before rekeying. Commit ciphertext only; avoid editor backups
of plaintext. Declare files with `age.secrets` on their consuming host and pass
the runtime path to services—never read decrypted values into Nix settings.

Editing or rekeying decrypts the file, so it needs the recovery key or the host
key. Files encrypted before the recovery key replaced the administrator keys
still open with those keys until they are written again. Removing a recipient
cannot revoke old Git history; rotate credentials if a key is compromised.
