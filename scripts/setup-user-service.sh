#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/lib/common.sh"
root_required
[[ $# -eq 2 ]] || die 'Usage: setup-user-service.sh OWNER NAME'
git_account
require_repo "$1" "$2"
config_dir="$GIT_HOME/.push-n-deploy/$REPO_REL"
[[ -f $config_dir/config && -f $config_dir/lock ]] || die 'Run setup-deployment.sh first.'
source "$config_dir/config"
default_service="$1.$2.service"
[[ ! -f $config_dir/service ]] || default_service=$(cat "$config_dir/service")
printf 'Set up a systemd user service on %s, working in %s/current.\n' "$target" "$destination"
read -r -p "Service name [$default_service]: " service || die 'No service name input.'
service=${service:-$default_service}
[[ $service == *.service ]] || service+=.service
[[ $service =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*\.service$ ]] || die 'Use a simple service name containing letters, digits, dots, underscores or hyphens.'
[[ ! -f $config_dir/service || $service == "$default_service" ]] || die 'This deployment already has a service; edit it using the same name.'
printf 'The service will run make run from the current release.\n'
read -r -p 'Restart policy (on-failure/always/no) [on-failure]: ' restart_policy || die 'No restart policy input.'
restart_policy=${restart_policy:-on-failure}
[[ $restart_policy == on-failure || $restart_policy == always || $restart_policy == no ]] || die 'Invalid restart policy.'
read -r -p 'Run after logout and at boot (enable lingering)? [Y/n]: ' linger || die 'No lingering input.'
case ${linger,,} in
  ''|y|yes) linger=yes ;;
  n|no) linger=no ;;
  *) die 'Answer yes or no for lingering.' ;;
esac
quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
remote_command="bash -c $(quote "$(cat "$script_dir/lib/mise.sh" "$script_dir/lib/install-user-service.sh")") bash"
for argument in "$REPO_REL" "$destination" "$service" "$restart_policy" "$linger"; do
  remote_command+=" $(quote "$argument")"
done
exec 9<>"$config_dir/lock"
flock 9
runuser -u "$GIT_USER" -- ssh -F /dev/null \
  -i "$config_dir/identity" -p "$port" \
  -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$config_dir/known_hosts" -o GlobalKnownHostsFile=/dev/null \
  -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  "$target" "$remote_command" < /dev/null
install_deployment_hooks "$script_dir" "$config_dir"
service_tmp=$(mktemp "$config_dir/.service.XXXXXXXX")
trap 'rm -f -- "$service_tmp"' EXIT
printf '%s\n' "$service" > "$service_tmp"
chown root:"$GIT_GID" "$service_tmp"
chmod 640 "$service_tmp"
mv -f -- "$service_tmp" "$config_dir/service"
printf 'Service %s is enabled. The next successful deployment will start/restart it.\n' "$service"
