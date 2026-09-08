#!/usr/bin/env bash
set -euo pipefail
umask 027
destination=$1 service=${2:-}
[[ -d $destination ]] || release_error 'Target application directory does not exist.'
initialize_releases
[[ -L current ]] || release_error 'No current release to roll back.'
current_release=$(readlink current)
[[ $current_release == releases/* ]] && valid_release_name "${current_release#releases/}" || release_error 'current does not point to a managed release.'
[[ ${#release_history[@]} -gt 0 ]] || release_error 'No successful-release history. Update deployment hooks and deploy successfully before using rollback; older untracked directories cannot be verified.'
# If current is an unsuccessful activation, the newest recorded success is the fallback.
start=0
for index in "${!release_history[@]}"; do
  if [[ ${release_history[index]} == "${current_release#releases/}" ]]; then
    start=$((index + 1))
    break
  fi
done
selected=-1
for ((index=start; index<${#release_history[@]}; index++)); do
  candidate="$destination/releases/${release_history[index]}"
  if [[ -d $candidate && ! -L $candidate && $(realpath -e -- "$candidate") == "$candidate" ]]; then
    selected=$index
    break
  fi
done
[[ $selected -ge 0 ]] || release_error 'No previous successful release is available on the target.'
release="$destination/releases/${release_history[selected]}"
printf 'Rolling back from %s to releases/%s.\n' "${current_release#releases/}" "${release_history[selected]}"
activate_release "$release"
# Consume newer entries so repeated rollbacks walk backward, rather than toggling.
save_release_history "${release_history[@]:selected}"
printf 'Rollback succeeded: %s\n' "$release"
