#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
root_required
[[ $# -eq 0 ]] || die 'Usage: setup-git-user.sh (optional GIT_USER environment variable)'
GIT_USER=${GIT_USER:-git}
[[ $GIT_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die 'Invalid GIT_USER.'
shell=$(command -v git-shell) || die 'Install dependencies first.'
home="/srv/$GIT_USER"
if getent passwd "$GIT_USER" >/dev/null; then
  git_account
  [[ $GIT_HOME == "$home" ]] || die "Existing account has a different home; expected $home."
else
  [[ ! -e $home ]] || die "Refusing to adopt existing directory: $home"
  useradd --create-home --home-dir "$home" --shell "$shell" --user-group "$GIT_USER"
fi
git_account
passwd --lock "$GIT_USER" >/dev/null
# Root owns authentication and configuration; Git can write only repository data.
chown root:"$GIT_GID" "$GIT_HOME"
chmod 755 "$GIT_HOME"
install -d -o root -g "$GIT_GID" -m 750 "$GIT_HOME/.ssh" "$GIT_HOME/.push-n-deploy"
if [[ ! -e $GIT_HOME/.ssh/authorized_keys ]]; then
  install -o root -g "$GIT_GID" -m 640 /dev/null "$GIT_HOME/.ssh/authorized_keys"
fi
printf 'Git account ready: %s (home %s, shell %s)\n' "$GIT_USER" "$GIT_HOME" "$GIT_SHELL"
