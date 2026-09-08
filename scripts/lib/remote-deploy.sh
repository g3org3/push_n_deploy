#!/usr/bin/env bash
set -euo pipefail
umask 027
destination=$1 revision=$2
[[ $destination == /* && $destination != / && $revision =~ ^[a-f0-9]{40,64}$ ]] || exit 1
mkdir -p -- "$destination/releases"
cd -- "$destination"
exec 8>.deploy.lock
flock 8
if [[ -e current && ! -L current ]]; then
  printf 'Refusing to replace current: expected a symlink.\n' >&2
  exit 1
fi
release=$(mktemp -d "$PWD/releases/$revision.XXXXXXXX")
tar --extract --file=- --directory="$release" --no-same-owner --no-same-permissions
cd -- "$release"
export PUSH_DEPLOY_REVISION="$revision"
make deploy
cd -- "$destination"
link=".current.${release##*/}"
trap 'rm -f -- "$link"' EXIT
ln -s -- "releases/${release##*/}" "$link"
mv -Tf -- "$link" current
printf 'Release ready: %s\n' "$release"
