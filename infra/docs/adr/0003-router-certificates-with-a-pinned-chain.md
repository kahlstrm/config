# 3. Issue router certificates with new keys and pin the issuer chain

- Status: accepted
- Date: 2026-10-25

## Context

Terraform manages the routers through `www-ssl` and verifies its Let's Encrypt
certificate, so a router serving an incomplete chain blocks Terraform as well
as clients. RouterOS constrains how that certificate can be replaced:

- `/ip service` binds to a certificate's internal ID, not its name.
- `www-ssl` workers find their leaf by subject key identifier, which Let's
  Encrypt derives from the key, and look up its chain when they start. A new
  leaf with the old key is served as the old one, and a worker that starts
  while an intermediate is missing serves the leaf without it.
- Importing a certificate with the subject and key of an installed one
  overwrites that entry. Two versions of an intermediate cannot coexist.

Let's Encrypt picks an intermediate (YR1–YR3) per issuance, and ACME returns it
only with the issued certificate, which is too late to install it first.

## Decision

- Order a certificate with a new key on the first apply of each month. Install
  it under a per-issuance name, create before destroy, then rebind `api_ssl`
  and `www_ssl`.
- Pin every intermediate and the cross-signed root on each router in their own
  module, fetched from letsencrypt.org. Renewals never touch them.
- Keep the installed copy of a pinned certificate when its published content
  changes. A re-issue under the same name and key cannot replace it without a
  gap, and the installed copy completes the chain of leaves from either one.
- Before installing a leaf, require its issuers' subjects to be pinned. After
  RouterOS reports the leaf's issuer key, require an installed certificate with
  that key, before the services rebind.

Rejected: installing the chain from each issuance, since `for_each` keys are
unknown at plan time and RouterOS deduplicates the shared certificates; and
create before destroy for chain certificates, which RouterOS turns into an
overwrite.

## Consequences

- Plans fetch the chain from letsencrypt.org and fail if it is unreachable.
- A leaf from an unpinned intermediate, or from a pinned name with a new key,
  fails the apply while the router keeps serving the previous leaf.
- A re-issued intermediate is never installed by Terraform. The
  `chain_expiry` check warns 90 days before an installed copy expires; see
  [Certificates](../../local-networking/README.md#certificates).
- Retiring an intermediate is safe only after both routers serve leaves from
  another, since the checks cover the leaf being installed.
