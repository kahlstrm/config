# TODO

- [ ] Assess whether sharing the network inventory between Terraform and Nix
  makes sense, including agent DNS and firewall settings. If worthwhile, move
  the full inventory (hosts, addresses, subnets, gateways, DNS names, MAC
  addresses, and DHCP reservations) into shared JSON in a separate PR.
  Keep credentials and access policies separate from inventory.
