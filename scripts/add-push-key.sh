#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
root_required
[[ $# -eq 1 ]] || die 'Usage: add-push-key.sh PUBLIC_KEY_FILE'
git_account
[[ -f $1 ]] || die 'Public key file not found.'
mapfile -t lines < "$1"
[[ ${#lines[@]} -eq 1 ]] || die 'Provide exactly one public key, without authorized_keys options.'
read -r type blob comment <<< "${lines[0]}"
[[ $type == ssh-ed25519 || $type == ssh-rsa || $type == ecdsa-sha2-* ]] || die 'Unsupported key type (use Ed25519, RSA, or ECDSA).'
ssh-keygen -lf "$1" >/dev/null || die 'Invalid public key.'
keys="$GIT_HOME/.ssh/authorized_keys"
exec 9>"$GIT_HOME/.ssh/.keys.lock"
flock 9
while read -r options existing_type existing_blob rest; do
  if [[ $options == restrict && $existing_type == "$type" && $existing_blob == "$blob" ]]; then
    printf 'Key already authorized.\n'
    exit 0
  fi
done < "$keys"
printf 'restrict %s %s%s\n' "$type" "$blob" "${comment:+ $comment}" >> "$keys"
printf 'Key authorized for all repositories owned by %s.\n' "$GIT_USER"
