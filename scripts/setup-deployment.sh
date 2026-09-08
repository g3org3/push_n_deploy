#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/lib/common.sh"
root_required
[[ $# -ge 6 && $# -le 8 ]] || die 'Usage: setup-deployment.sh OWNER NAME USER@HOST TARGET_DIR PRIVATE_KEY KNOWN_HOSTS [BRANCH=main] [PORT=22]'
git_account
require_repo "$1" "$2"
target=$3 destination=$4 identity=$5 known_hosts=$6 branch=${7:-main} port=${8:-22}
[[ $target =~ ^[a-z_][a-zA-Z0-9_-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die 'Use USER@HOST (DNS name or IPv4 address).'
[[ $destination == /* && $destination != / && $destination != *$'\n'* ]] || die 'TARGET_DIR must be an absolute, dedicated application directory, not /.'
git check-ref-format "refs/heads/$branch" || die 'Invalid branch.'
[[ $port =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || die 'Invalid SSH port.'
[[ -f $identity && -s $known_hosts ]] || die 'Provide a private key and a nonempty verified known_hosts file.'
ssh-keygen -y -P '' -f "$identity" >/dev/null || die 'Deployment key must be valid and usable without a passphrase.'
host=${target#*@}
[[ $port == 22 ]] || host="[$host]:$port"
ssh-keygen -F "$host" -f "$known_hosts" >/dev/null || die "known_hosts has no entry for $host."
config_dir="$GIT_HOME/.push-n-deploy/$REPO_REL"
hook="$REPO/hooks/post-receive"
[[ ! -e $config_dir && ! -e $hook ]] || die 'Deployment configuration or post-receive hook already exists; inspect it before replacing it.'
install -d -o root -g "$GIT_GID" -m 750 "$GIT_HOME/.push-n-deploy/$1" "$config_dir"
install -o root -g "$GIT_GID" -m 640 "$identity" "$config_dir/identity"
install -o root -g "$GIT_GID" -m 640 "$known_hosts" "$config_dir/known_hosts"
install -o "$GIT_USER" -g "$GIT_GID" -m 600 /dev/null "$config_dir/lock"
install -o root -g "$GIT_GID" -m 640 "$script_dir/lib/remote-deploy.sh" "$config_dir/remote-deploy.sh"
{
  printf 'target=%q\ndestination=%q\nbranch=%q\nport=%q\n' "$target" "$destination" "$branch" "$port"
} > "$config_dir/config"
chown root:"$GIT_GID" "$config_dir/config"
chmod 640 "$config_dir/config"
{
  printf '#!/usr/bin/env bash\nconfig_dir=%q\n' "$config_dir"
  cat "$script_dir/lib/post-receive.sh"
} > "$hook"
chown root:"$GIT_GID" "$hook"
chmod 750 "$hook"
printf 'Pushes to %s will deploy to %s:%s.\n' "$branch" "$target" "$destination"
