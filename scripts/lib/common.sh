#!/usr/bin/env bash

set -euo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
root_required() { [[ $EUID -eq 0 ]] || die 'Run this script with sudo/root.'; }
git_account() {
  GIT_USER=${GIT_USER:-git}
  [[ $GIT_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die 'Invalid GIT_USER.'
  local entry
  entry=$(getent passwd "$GIT_USER") || die 'Run setup-git-user.sh first.'
  IFS=: read -r _ _ _ GIT_GID _ GIT_HOME GIT_SHELL <<< "$entry"
  [[ $GIT_SHELL == */git-shell && $GIT_HOME == /* && $GIT_HOME != / ]] || die 'Expected a dedicated account using git-shell.'
}
repo_name() {
  [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ && $1 != git-shell-commands ]] || die 'Owner must contain only letters, digits, underscores and hyphens; git-shell-commands is reserved.'
  [[ $2 =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || die 'Repository names must contain only letters, digits, underscores and hyphens (no .git suffix).'
  OWNER_DIR="$GIT_HOME/$1"
  [[ ! -L $OWNER_DIR ]] || die 'Owner directory must not be a symlink.'
  REPO_REL="$1/$2"
  REPO="$GIT_HOME/$REPO_REL"
}
require_repo() {
  repo_name "$1" "$2"
  [[ -d $REPO && ! -L $REPO ]] || die "Repository does not exist: $REPO"
  [[ $(runuser -u "$GIT_USER" -- git --git-dir="$REPO" rev-parse --is-bare-repository) == true ]] || die 'Expected a bare repository.'
}
install_deployment_hooks() {
  local script_dir=$1 config_dir=$2 hook_tmp builds_dir
  builds_dir="$GIT_HOME/.push_n_deploy/$REPO_REL"
  install -d -o root -g "$GIT_GID" -m 750 "$GIT_HOME/.push_n_deploy" "$GIT_HOME/.push_n_deploy/${REPO_REL%/*}"
  install -d -o "$GIT_USER" -g "$GIT_GID" -m 700 "$builds_dir"
  cat "$script_dir/lib/mise.sh" "$script_dir/lib/releases.sh" "$script_dir/lib/remote-deploy.sh" > "$config_dir/remote-deploy.sh"
  chown root:"$GIT_GID" "$config_dir/remote-deploy.sh"
  chmod 640 "$config_dir/remote-deploy.sh"
  install -o root -g "$GIT_GID" -m 640 "$script_dir/lib/prepare-artifact.sh" "$config_dir/prepare-artifact.sh"
  hook_tmp=$(mktemp "$REPO/hooks/.post-receive.XXXXXXXX")
  {
    printf '#!/usr/bin/env bash\nconfig_dir=%q\nbuilds_dir=%q\n' "$config_dir" "$builds_dir"
    cat "$script_dir/lib/post-receive.sh"
  } > "$hook_tmp"
  chown root:"$GIT_GID" "$hook_tmp"
  chmod 750 "$hook_tmp"
  mv -f -- "$hook_tmp" "$REPO/hooks/post-receive"
}
