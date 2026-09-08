#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
root_required
[[ $# -eq 2 ]] || die 'Usage: create-repo.sh OWNER NAME'
host=$(hostname -f 2>/dev/null || hostname)
[[ $host =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die 'Server hostname must be a DNS name or IPv4 address.'
git_account
repo_name "$1" "$2"
[[ ! -e $REPO && ! -L $REPO ]] || die "Repository already exists: $REPO"
install -d -o root -g "$GIT_GID" -m 755 "$OWNER_DIR"
install -d -o "$GIT_USER" -g "$GIT_GID" -m 750 "$REPO"
runuser -u "$GIT_USER" -- git init --bare --initial-branch=main "$REPO"
runuser -u "$GIT_USER" -- git --git-dir="$REPO" config receive.denyNonFastForwards true
remote="$GIT_USER@$host:$REPO_REL"
cat <<EOF

Repository created: $REPO_REL
Remote URL: $remote

…or create a new repository on the command line

echo "# $2" >> README.md
git init
git add README.md
git commit -m "first commit"
git branch -M main
git remote add origin $remote
git push -u origin main

…or push an existing repository from the command line

git remote add origin $remote
git branch -M main
git push -u origin main
EOF
