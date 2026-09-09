#!/usr/bin/env bash
# Per-push deploy worker, spawned by server.ts.
# Usage: deploy.sh OWNER REPO REVISION
# Reads /srv/git/.github_webhook/OWNER/REPO/config and shared SSH material at
# the .github_webhook root: identity (one deploy key for all repos) and
# known_hosts. Clones the repo, runs make build (mise-aware), and ships the
# build output to the target where `make deploy` activates it.
set -euo pipefail
umask 077
root=${GITHUB_WEBHOOK_ROOT:-/srv/git/.github_webhook}
[[ $# -eq 3 ]] || { printf 'Usage: deploy.sh OWNER REPO REVISION\n' >&2; exit 1; }
owner=$1 repo=$2 revision=$3
[[ $owner =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ && $repo =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || { printf 'Invalid owner/repo.\n' >&2; exit 1; }
[[ $revision =~ ^[0-9a-f]{40}$ ]] || { printf 'Invalid revision.\n' >&2; exit 1; }
repo_dir=$root/$owner/$repo
[[ -f $repo_dir/config ]] || { printf 'Not registered: %s/%s\n' "$owner" "$repo" >&2; exit 1; }
# shellcheck disable=SC1091
source "$repo_dir/config"

die() { printf 'Deploy error: %s\n' "$*" >&2; exit 1; }
[[ $repo_url == https://github.com/*/*.git ]] || die 'repo_url must be a https://github.com/OWNER/REPO.git clone URL.'
[[ $target =~ ^[a-z_][a-zA-Z0-9_-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die 'Invalid target in config.'
[[ $destination == /* && $destination != / ]] || die 'Invalid destination in config.'
[[ $branch =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die 'Invalid branch in config.'
[[ $port =~ ^[0-9]{1,5}$ ]] || die 'Invalid port in config.'
[[ -z $service || $service =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*\.service$ ]] || die 'Invalid service name in config.'
[[ -f $root/identity && -s $root/known_hosts ]] || die 'Shared deploy key or known_hosts missing at the .github_webhook root.'

# A push raced ahead of us: deploy only the latest revision, skip stale runs.
exec 9>"$repo_dir/.lock"
flock 9
if [[ -f $repo_dir/state/deployed && $(< "$repo_dir/state/deployed") == "$revision" ]]; then
  printf 'Already deployed: %s\n' "$revision"
  exit 0
fi

work_dir=
cleanup() { [[ -z $work_dir ]] || rm -rf -- "$work_dir"; }
trap cleanup EXIT
work_dir=$(mktemp -d /tmp/github-webhook.XXXXXXXX)
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
unset MAKEFLAGS MFLAGS MAKELEVEL

printf 'Deploying %s/%s %s to %s:%s\n' "$owner" "$repo" "$revision" "$target" "$destination"

clone_dir=$work_dir/repo
git clone --quiet --depth 1 --branch "$branch" "$repo_url" "$clone_dir" || die 'Clone failed.'
cd "$clone_dir"
if [[ $(git rev-parse HEAD) != "$revision" ]]; then
  # GitHub serves fetches of any SHA reachable from a branch.
  git fetch --quiet --depth 1 origin "$revision" || die "Revision $revision is not reachable on $branch."
  git checkout --quiet --detach "$revision"
fi
printf 'Cloned %s.\n' "$(git rev-parse --short HEAD)"

# Read output_dir from .push_n_deploy.yml (same convention as push_n_deploy).
output_dir=dist
if [[ -e .push_n_deploy.yml ]]; then
  [[ -f .push_n_deploy.yml && ! -L .push_n_deploy.yml ]] || die 'Expected a regular .push_n_deploy.yml file.'
  while IFS= read -r line; do
    line=${line%%#*}
    # shellcheck disable=SC2001
    value=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*output_dir:[[:space:]]*//' -e 's/["'\'']//g' -e 's/[[:space:]]*$//')
    [[ $value == "$line" ]] && continue
    [[ -n $value ]] || die 'output_dir must not be empty.'
    output_dir=$value
  done < .push_n_deploy.yml
fi
output_dir=${output_dir#./}; output_dir=${output_dir%/}
[[ $output_dir =~ ^[a-zA-Z0-9_./\ -]+$ && $output_dir != /* ]] || die "Invalid output_dir: $output_dir"
[[ $output_dir != *..* ]] || die 'output_dir must stay inside the checkout.'

makefile=
for candidate in GNUmakefile makefile Makefile; do
  if [[ -f $candidate ]]; then makefile=$candidate; break; fi
done
[[ -n $makefile && ! -L $makefile ]] || die 'A regular Makefile is required.'

printf 'Building (output: %s).\n' "$output_dir"
if [[ -e mise.toml || -L mise.toml ]]; then
  [[ -f mise.toml && ! -L mise.toml ]] || die 'mise.toml must be a regular file.'
  mise trust ./mise.toml
  mise install
  mise exec -- make build
else
  make build
fi
[[ -d $output_dir ]] || die "Build did not produce output directory: $output_dir"

artifact_files=("$makefile" "$output_dir")
[[ -e mise.toml ]] && artifact_files+=(mise.toml)
tar -czf "$work_dir/artifact.tar.gz" -- "${artifact_files[@]}"

# Remote activation: extract into a fresh release, run make deploy there, and
# switch the current symlink only on success. Mirrors push_n_deploy's flow.
remote_script=$(cat <<'REMOTE'
set -euo pipefail
destination=$1 revision=$2 service=${3:-}
[[ $destination == /* && $destination != / ]] || exit 1
mkdir -p -- "$destination/releases"
cd -P -- "$destination"
exec 8>.github_webhook.lock
flock 8
release=$(mktemp -d -- "$destination/releases/$revision.XXXXXXXX")
tar --extract --gzip --file=- --directory="$release" --no-same-owner --no-same-permissions
cd -- "$release"
export PUSH_DEPLOY_REVISION=$revision PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
if [[ -e mise.toml || -L mise.toml ]]; then
  [[ -f mise.toml && ! -L mise.toml ]] || exit 1
  if ! command -v mise >/dev/null; then
    command -v curl >/dev/null || exit 1
    mkdir -p -- "$HOME/.local/bin"
    curl -fsSL https://mise.run | MISE_INSTALL_PATH="$HOME/.local/bin/mise" sh
    export PATH="$HOME/.local/bin:$PATH"
  fi
  mise trust ./mise.toml
  mise install
  mise exec -- make deploy
else
  make deploy
fi
cd -P -- "$destination"
ln -s -- "releases/${release##*/}" "$destination/.activate.$$"
mv -Tf -- "$destination/.activate.$$" "$destination/current"
if [[ -n $service ]]; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
  systemctl --user restart "$service"
  systemctl --user is-active --quiet "$service"
fi
# Keep the newest three releases.
cd "$destination/releases"
set -- $(ls -1t -- */ 2>/dev/null | sed 's|/*$||')
if [[ $# -gt 3 ]]; then shift 3; rm -rf -- "$@"; fi
printf 'Release ready: %s\n' "$release"
REMOTE
)
quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
remote_command="bash -c $(quote "$remote_script") bash $(quote "$destination") $(quote "$revision") $(quote "$service")"
[[ $port == 22 ]] || target_ssh="[$target]"
ssh -F /dev/null \
  -i "$root/identity" -p "$port" \
  -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$root/known_hosts" -o GlobalKnownHostsFile=/dev/null \
  -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  "$target" "$remote_command" < "$work_dir/artifact.tar.gz"

install -d -m 700 "$repo_dir/state"
printf '%s\n' "$revision" > "$repo_dir/state/deployed.tmp"
mv -f -- "$repo_dir/state/deployed.tmp" "$repo_dir/state/deployed"
printf 'Deployment succeeded: %s\n' "$revision"
