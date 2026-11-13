{
  administrators = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPp11x78hP1TOHinNlmZhPpVxBczbxjygYeTZB5pwOq+"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM2hL8oTIrptaIITRohmNGAU+BQspIjf+eB5x+IJPF9v"
  ];
  # Offline recovery key: a recipient of every encrypted file instead of the administrator
  # keys, held only offline. infra/local-kubernetes/apps/backup/recovery-recipient holds a copy.
  recovery = "age1aqrvrftanv2n5xs9lhydcrmltm7fkecz78ncneywva9c5m759c2q0uc4y3";
  # SOPS recipient; the klusse cluster's Flux holds the private key.
  kubernetes.klusse = "age180272we8y2gkjqj7gplv8z2a2q09qwx9v55884fplsjcxagvagvsdn089u";
  builders.pannu = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ2MJIgY9K0pzFIPnk4D7mFGLSwbJ1koDvWrnKvBsNx4 frame-work-pannu-builder"
  ];
  # The cluster's backup jobs upload to the write-only drop on zima and pannu with this key
  # (modules/backup.nix); its private half is the `backup-drop` Secret in
  # infra/local-kubernetes/apps/backup.
  backupDrop = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtuOK6i4ateNOBbeVi+2ylSbl/HJjYP9yyCuow1zafB backup-drop";
  # Ops' deploy key, generated on ops; see modules/agent-ops/default.nix.
  deployers.ops = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICI7ZuQMRv7nG3uUsjJfk8npXZCmxNQ8QEtSSwTVJOCU ops-deploy"
  ];
  hosts = {
    "pannu-agents" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILjupE0ttR9L7iIY8pT/jUgQUa9AAH6kNjSd9zClKMeX";
    # ops' host key, which sops-nix on ops decrypts its secrets with; see modules/agent-ops.
    "pannu-ops" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZLXJ4bR4wEtAY2bzbEg2e9QGd7lM1bM7XlsLs4rAZx";
    "jet.kalski.xyz" =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJuFoL+bSI5l0VM9kkl6Fj5g2yMor9osv2rnTNLz3KKR";
    "p.kalski.xyz" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFk8+06RzXtg+i6G8YZBB4YPHB55FyhtpgjELqU5bYMF";
    "zima.kalski.xyz" =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMmcvigFoEOoYiWl/7NDMjL/82e0Xq+3n/M2mW30XQji";
    "poenttoe.kalski.xyz" =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM3Ej4EpcyblV2ULtqb9sCg8vM1zH96sy/eVjwEzv/l6";
  };
}
