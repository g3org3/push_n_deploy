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
service=
if [[ -f $config_dir/service ]]; then
  service=$(cat "$config_dir/service")
  [[ $service =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*\.service$ ]] || { printf 'Invalid configured service name.\n' >&2; exit 1; }
fi
# A newer push may have arrived while this hook was waiting.
[[ $(git rev-parse --verify "refs/heads/$branch" 2>/dev/null || true) == "$revision" ]] || exit 0
work_dir=
artifact_tmp=
cleanup() {
  status=$?
  [[ -z $work_dir ]] || rm -rf -- "$work_dir"
  [[ -z $artifact_tmp ]] || rm -f -- "$artifact_tmp"
  if [[ $status -ne 0 ]]; then
    printf 'DEPLOYMENT FAILED: %s. Git accepted the push; inspect the build/target output and retry deployment.\n' "$revision" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
umask 077
work_dir=$(mktemp -d)
git archive --format=tar "$revision" > "$work_dir/source.tar"
# Build tools must not inherit receive-pack's repository environment.
while IFS= read -r variable; do unset "$variable"; done < <(git rev-parse --local-env-vars)
unset MAKEFLAGS MFLAGS MAKELEVEL
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
bash "$config_dir/prepare-artifact.sh" "$work_dir" "$revision"
# Publish only complete archives. Staging and the final rename share a filesystem.
artifact_tmp=$(mktemp "$builds_dir/.artifact.XXXXXXXX")
cp -- "$work_dir/artifact.tar.gz" "$artifact_tmp"
artifact="$builds_dir/$(date -u +%Y%m%dT%H%M%S.%N)-$revision-${artifact_tmp##*.}.tar.gz"
mv -- "$artifact_tmp" "$artifact"
artifact_tmp=
prune_builds() {
  local LC_ALL=C
  local -a archives=("$builds_dir"/*.tar.gz)
  local index
  for ((index=0; index<${#archives[@]}-3; index++)); do
    rm -f -- "${archives[index]}"
  done
}
# The repository lock covers publication, retention, and transfer.
prune_builds
printf 'Saved artifact: %s (keeping the latest 3).\n' "$artifact"
quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
remote_command="bash -c $(quote "$(cat "$config_dir/remote-deploy.sh")") bash $(quote "$destination") $(quote "$revision") $(quote "$service")"
printf 'Deploying %s (%s) to %s\n' "$branch" "$revision" "$target"
ssh -F /dev/null \
  -i "$config_dir/identity" -p "$port" \
  -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$config_dir/known_hosts" -o GlobalKnownHostsFile=/dev/null \
  -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  "$target" "$remote_command" < "$artifact"
printf 'Deployment succeeded: %s\n' "$revision"
