# hetzner-infra

Terraform layer for Hetzner Cloud resources.

## Bootstrap

1. Authenticate to GCP (Terraform backend + Secret Manager):

   ```bash
   gcloud auth application-default login
   ```

2. Create the Secret Manager secret for this layer:

   ```bash
   terraform init
   terraform apply -target module.secrets
   ```

3. Set the Hetzner API token in the `hetzner-infra` secret:

   ```bash
   just edit
   ```

Use this JSON shape:

```json
{
  "hcloud_token": "..."
}
```

## Bootstrap Mode

Enable temporary public SSH access for initial setup (nixos-infect runs automatically on first boot):

```bash
TF_VAR_BOOTSTRAP=true terraform apply
```

## Storage Box

`storage-box.tf` creates the Storage Box for off-site backups
([docs/backups.md](../../docs/backups.md)) and its `restic` subaccount, which the hosts
log in to with the backup SSH key. Neither account accepts connections from outside
Hetzner's network: poenttoe connects directly, and pannu and zima jump through it.
Hetzner keeps daily snapshots of the box that no SFTP login can delete.

Hetzner has no IP allowlist, and SFTP, FTP and password login can't be turned off, so
the passwords matter. Each account needs one, and the provider stores both in this
layer's state. The provider never reads them back, so resetting them in the Console
leaves the plan clean.

Set up once, from a maintainer's machine:

1. Create the box with the subaccount reachable from outside, because the API can't set
   a subaccount's SSH keys:

   ```bash
   TF_VAR_STORAGE_BOX_SETUP=true terraform apply
   ```

2. Record the subaccount's host key, because `sshpass` can't answer SSH's prompt for it.
   Add it only if its fingerprint is one that Hetzner publishes
   ([SSH host keys](https://docs.hetzner.com/storage/storage-box/general#ssh-host-keys)):

   ```bash
   repo=$(terraform output -raw backup_offsite_repository); login=${repo#sftp://}; login=${login%%:*}
   hostkey=$(ssh-keyscan -p 23 -t ed25519 "${login#*@}" 2>/dev/null)
   printf '%s\n' "$hostkey" | ssh-keygen -lf -
   printf '%s\n' "$hostkey" >> ~/.ssh/known_hosts
   ```

3. Install the backup key on the subaccount, with its password from the state:

   ```bash
   SSHPASS=$(terraform show -json | jq -r '.values.root_module.resources[]
     | select(.address == "random_password.storage_box[\"restic\"]") | .values.result') \
   nix shell nixpkgs#sshpass --command sh -c \
     "nix eval --raw --file ../../lib/ssh-keys.nix backup | sshpass -e ssh -p 23 $login install-ssh-key"
   ```

4. Apply again without the variable, which closes the subaccount to outside connections.
5. Check that a connection from outside Hetzner is refused and that poenttoe gets in.
6. In the Hetzner Console, reset both passwords. Keep the main account's in a password
   manager; discard the subaccount's.

`terraform output backup_offsite_repository` prints the restic repository location, which
goes to `backup/offsite` in the private secrets repository.

## ZeroTier Setup

The ZeroTier identity and network membership for this server (`poenttoe`) are managed in the `local-networking` layer. After the server is provisioned and running NixOS, you must manually configure ZeroTier to match the pre-authorized identity.

1.  **Get the Identity Key:**
    Retrieve the generated private key from the `local-networking` layer:

    ```bash
    cd ../local-networking
    terraform output -raw poenttoe_zerotier_private_key
    ```

    *Note: This output is the content of the `identity.secret` file.*

2.  **Get the Network ID:**

    ```bash
    terraform output -raw zerotier_network_id
    ```

3.  **Configure the Server:**
    SSH into `poenttoe` and run the following (replace `<PRIVATE_KEY_CONTENT>` and `<NETWORK_ID>`):

    ```bash
    # Stop the service
    sudo systemctl stop zerotierone

    # Write the identity file (be careful with permissions!)
    sudo echo "<PRIVATE_KEY_CONTENT>" > /var/lib/zerotier-one/identity.secret
    sudo chmod 600 /var/lib/zerotier-one/identity.secret
    sudo chown zerotier-one:zerotier-one /var/lib/zerotier-one/identity.secret

    # Start the service
    sudo systemctl start zerotierone

    # Join the network
    sudo zerotier-cli join <NETWORK_ID>
    ```

4.  **Verify:**
    The server should automatically be authorized and assigned the IP `10.255.255.3` (DNS: `poenttoe.kalski.xyz`).