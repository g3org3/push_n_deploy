#!/usr/bin/env bash
set -euo pipefail
umask 027
destination=$1 revision=$2 service=${3:-}
[[ $destination == /* && $destination != / && $revision =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]] || exit 1
mkdir -p -- "$destination/releases"
initialize_releases
release=$(mktemp -d "$destination/releases/$revision.XXXXXXXX")
tar --extract --gzip --file=- --directory="$release" --no-same-owner --no-same-permissions
activate_release "$release"
save_release_history "${release##*/}" "${release_history[@]}"
printf 'Release ready: %s\n' "$release"
