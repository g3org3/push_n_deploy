#!/usr/bin/env bash
set -euo pipefail
source "$config_dir/config"
revision=
while read -r old new ref; do
  if [[ $ref == "refs/heads/$branch" && ! $new =~ ^0+$ ]]; then revision=$new; fi
done
[[ -n $revision ]] || exit 0
exec 9<>"$config_dir/lock"
flock 9
# A newer push may have arrived while this hook was waiting.
[[ $(git rev-parse --verify "refs/heads/$branch" 2>/dev/null || true) == "$revision" ]] || exit 0
quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
remote_command="bash -c $(quote "$(cat "$config_dir/remote-deploy.sh")") bash $(quote "$destination") $(quote "$revision")"
printf 'Deploying %s (%s) to %s\n' "$branch" "$revision" "$target"
if git archive --format=tar "$revision" | ssh -F /dev/null \
  -i "$config_dir/identity" -p "$port" \
  -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$config_dir/known_hosts" -o GlobalKnownHostsFile=/dev/null \
  -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  "$target" "$remote_command"; then
  printf 'Deployment succeeded: %s\n' "$revision"
else
  printf 'DEPLOYMENT FAILED: %s. Git accepted the push; inspect the target and retry deployment.\n' "$revision" >&2
  exit 1
fi
