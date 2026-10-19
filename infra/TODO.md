# TODO

- [ ] Assess whether sharing the network inventory between Terraform and Nix
  makes sense, including agent DNS and firewall settings. If worthwhile, move
  the full inventory (hosts, addresses, subnets, gateways, DNS names, MAC
  addresses, and DHCP reservations) into shared JSON in a separate PR.
  Keep credentials and access policies separate from inventory.
- [ ] Move the agenix host secrets (`secrets/*.age`) to sops-nix with the same
  `.sops.yaml`, hosts decrypting with their SSH host keys. The agents' GitHub
  App key and the Headscale OIDC secret are internet-usable, so decide where
  they belong rather than committing them as public ciphertext.
- [ ] Enforce NetworkPolicy: flannel ignores policies, so docsight's existing
  policy does nothing. Replace flannel with Cilium (installed from Talos's
  bootstrap manifests, since Flux needs a pod network first), then add
  default-deny policies per namespace with explicit allows for Traefik,
  Prometheus, DNS and API access. Afterwards docsight can drop its own password
  and rely on forward-auth. Do it after the Talos upgrades.
