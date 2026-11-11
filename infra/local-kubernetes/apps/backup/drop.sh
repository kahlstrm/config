# Uploads each given file to the write-only drop on zima and on pannu (modules/backup.nix),
# which back it up with their own state. Each upload replaces the previous one by renaming,
# so a host never backs up a half-written file. A failure on one host does not skip the other.
set -eu
install -m 600 /secrets/drop/ssh-key /tmp/key
status=0
for host in zima.kalski.xyz p.kalski.xyz; do
  for file in "$@"; do
    name=$(basename "$file")
    printf 'put %s %s.tmp\nrename %s.tmp %s\n' "$file" "$name" "$name" "$name" |
      sftp -F /config/ssh_config -b - "$host" >/dev/null || {
      echo "Uploading $name to $host failed." >&2
      status=1
    }
  done
done
exit "$status"
