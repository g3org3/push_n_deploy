#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/lib/common.sh"
root_required
[[ $# -eq 2 ]] || die 'Usage: update-deployment.sh OWNER NAME'
git_account
require_repo "$1" "$2"
config_dir="$GIT_HOME/.push-n-deploy/$REPO_REL"
[[ -f $config_dir/config && -f $config_dir/lock && -f $REPO/hooks/post-receive ]] || die 'Run setup-deployment.sh first.'
exec 9<>"$config_dir/lock"
flock 9
install_deployment_hooks "$script_dir" "$config_dir"
printf 'Deployment hooks updated for %s; settings and SSH keys preserved.\n' "$REPO_REL"
