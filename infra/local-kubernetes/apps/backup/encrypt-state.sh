# Encrypts the state to the offline recovery key's age public key before it leaves the pod,
# so the restic password and the drop open nothing in it (docs/backups.md).
set -eu
recipient=$(cat /config/recovery-recipient)
if [ -z "$recipient" ]; then
  echo "No recovery key yet: put its age public key in recovery-recipient (docs/backups.md)." >&2
  exit 1
fi
tar -C /work/state -cf /work/terraform-state.tar .
rm -r /work/state
sops encrypt --age "$recipient" --input-type binary --output-type json \
  --output /work/terraform-state.tar.sops /work/terraform-state.tar
rm /work/terraform-state.tar
