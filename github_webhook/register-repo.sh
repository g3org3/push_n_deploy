#!/usr/bin/env bash
# Register a GitHub repository for webhook-driven deployment.
# Prepares our side: shared SSH deploy key, per-repo config and webhook secret.
# Prints the gh CLI command that creates the webhook on GitHub (gh signs the
# payload with the same secret).
#
# Usage:
#   sudo bash register-repo.sh OWNER REPO \
#     --url https://github.com/OWNER/REPO.git \
#     --target deploy@target.example.com \
#     --dir /srv/apps/myapp \
#     [--branch main] [--port 22] [--service myapp.service] \
#     [--secret HEX32] [--identity PATH] [--known-hosts PATH] [--force]
#
# Reuses one shared deploy key for all repos (key management once, not per
# repo); pass --identity/--known-hosts only on first registration.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/../scripts/lib/common.sh"
root_required
git_account

[[ $# -ge 2 ]] || die 'Usage: register-repo.sh OWNER REPO --url URL --target USER@HOST --dir DIR [options]'
owner=$1 repo=$2; shift 2
[[ $owner =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ && $owner != git-shell-commands ]] || die 'Invalid owner name.'
[[ $repo =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || die 'Invalid repository name.'

base=${GIT_HOME:-/srv/git}/.github_webhook
url= target= destination= branch=main port=22 service= secret= identity= known_hosts= force=no
while [[ $# -gt 0 ]]; do
  case $1 in
    --url) url=$2; shift 2 ;;
    --target) target=$2; shift 2 ;;
    --dir) destination=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --port) port=$2; shift 2 ;;
    --service) service=$2; shift 2 ;;
    --secret) secret=$2; shift 2 ;;
    --identity) identity=$2; shift 2 ;;
    --known-hosts) known_hosts=$2; shift 2 ;;
    --force) force=yes; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ $url == https://github.com/*/*.git ]] || die 'URL must be https://github.com/OWNER/REPO.git.'
[[ $target =~ ^[a-z_][a-zA-Z0-9_-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die 'Use --target USER@HOST (DNS name or IPv4 address).'
[[ $destination == /* && $destination != / && $destination != *$'\n'* ]] || die 'Use --dir with an absolute, dedicated application directory, not /.'
git check-ref-format "refs/heads/$branch" || die 'Invalid branch.'
[[ $port =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || die 'Invalid SSH port.'
[[ -z $service || $service =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*\.service$ ]] || die 'Invalid service name.'

# Shared deploy key and host verification live at the root, set up once.
install -d -o root -g "$GIT_GID" -m 750 "$base"
install -d -o "$GIT_USER" -g "$GIT_GID" -m 700 "$base/$owner/$repo/logs"
if [[ -n $identity ]]; then
  [[ -f $identity && ! -L $identity ]] || die 'Identity must be a regular private key file.'
  ssh-keygen -y -P '' -f "$identity" >/dev/null || die 'Identity must be usable without a passphrase.'
  install -o root -g "$GIT_GID" -m 640 "$identity" "$base/identity"
elif [[ ! -f $base/identity ]]; then
  ssh-keygen -t ed25519 -N '' -C github-webhook -f "$base/identity" >/dev/null
fi
chmod 640 "$base/identity"; chown root:"$GIT_GID" "$base/identity"
if [[ -n $known_hosts ]]; then
  [[ -s $known_hosts && ! -L $known_hosts ]] || die 'known_hosts must be a nonempty file.'
  install -o root -g "$GIT_GID" -m 640 "$known_hosts" "$base/known_hosts"
elif [[ ! -s $base/known_hosts ]]; then
  die "No known_hosts yet. Verify the target host key first, e.g.:
  ssh-keyscan -H -p $port ${target#*@} > $base/known_hosts
  ssh-keygen -lf $base/known_hosts   # check it matches the host
then re-run with --known-hosts pointing at the verified file (or place it at $base/known_hosts)."
fi

if [[ -z $secret ]]; then
  if command -v openssl >/dev/null; then secret=$(openssl rand -hex 32)
  else secret=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'); fi
fi
[[ $secret =~ ^[0-9a-fA-F]{64}$ ]] || die 'Secret must be 64 hex characters.'

config=$base/$owner/$repo/config
if [[ -e $config && $force != yes ]]; then
  die "Already registered: $owner/$repo (use --force to overwrite)."
fi
umask 027
{
  printf 'repo_url=%q\nbranch=%q\ntarget=%q\ndestination=%q\nport=%q\nservice=%q\n' \
    "$url" "$branch" "$target" "$destination" "$port" "$service"
} > "$config"
printf '%s\n' "$secret" > "$base/$owner/$repo/secret"
chown root:"$GIT_GID" "$config" "$base/$owner/$repo/secret"
chmod 640 "$config" "$base/$owner/$repo/secret"

host=$(hostname -f 2>/dev/null || hostname)
webhook_port=${WEBHOOK_PORT:-9090}
printf '\nRegistered %s/%s -> %s:%s\n' "$owner" "$repo" "$target" "$destination"
if [[ ! -s $base/identity.pub ]]; then
  ssh-keygen -y -f "$base/identity" > "$base/identity.pub"
  chown root:"$GIT_GID" "$base/identity.pub"
  chmod 640 "$base/identity.pub"
  printf 'Deploy key saved. On %s, add this line to the deploy user'\''s ~/.ssh/authorized_keys:\n\n  restrict %s\n\n' "$target" "$(< "$base/identity.pub")"
fi
printf 'Create the webhook on GitHub (run as someone with gh access to %s/%s):\n\n' "$owner" "$repo"
printf '  gh api repos/%s/%s/hooks -X POST \\\n' "$owner" "$repo"
printf '    -f url="http://%s:%s/%s/%s" \\\n' "$host" "$webhook_port" "$owner" "$repo"
printf '    -f content_type=json -f secret=%q -f '"'"'events[]=push'"'"' -F active=true\n\n' "$secret"
printf 'Webhook endpoint: http://%s:%s/%s/%s (secret stored at %s)\n' "$host" "$webhook_port" "$owner" "$repo" "$base/$owner/$repo/secret"
