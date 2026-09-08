#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/lib/common.sh"
root_required
[[ $# -eq 2 ]] || die 'Usage: rollback.sh OWNER NAME'
git_account
require_repo "$1" "$2"
config_dir="$GIT_HOME/.push-n-deploy/$REPO_REL"
[[ -f $config_dir/config && -f $config_dir/lock ]] || die 'Run setup-deployment.sh first.'
exec 9<>"$config_dir/lock"
flock 9
source "$config_dir/config"
service=
[[ ! -f $config_dir/service ]] || service=$(cat "$config_dir/service")
quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
remote_command="bash -c $(quote "$(cat "$script_dir/lib/mise.sh" "$script_dir/lib/releases.sh" "$script_dir/lib/remote-rollback.sh")") bash $(quote "$destination") $(quote "$service")"
printf 'Rolling back %s on %s.\n' "$REPO_REL" "$target"
runuser -u "$GIT_USER" -- ssh -F /dev/null \
  -i "$config_dir/identity" -p "$port" \
  -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$config_dir/known_hosts" -o GlobalKnownHostsFile=/dev/null \
  -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  "$target" "$remote_command" < /dev/null
