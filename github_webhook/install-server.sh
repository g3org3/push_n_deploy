#!/usr/bin/env bash
# Install the GitHub webhook deploy server on the Git server.
# Installs bin/ (server.ts + deploy.sh) into /srv/git/.github_webhook, ensures
# Bun, and installs a systemd service running as the git account.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/../scripts/lib/common.sh"
root_required
git_account

base=${GIT_HOME:-/srv/git}/.github_webhook
port=${WEBHOOK_PORT:-9090}

install -d -o root -g "$GIT_GID" -m 750 "$base" "$base/bin"
install -o root -g "$GIT_GID" -m 640 "$script_dir/server.ts" "$base/bin/server.ts"
install -o root -g "$GIT_GID" -m 750 "$script_dir/deploy.sh" "$base/bin/deploy.sh"

# Bun, system-wide so the git account can run the server.
if [[ ! -x /usr/local/bin/bun ]] && ! command -v bun >/dev/null; then
  install -d -m 755 /usr/local/bin
  curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash
fi
bun_bin=$(command -v bun || printf '/usr/local/bin/bun')
"$bun_bin" --version

unit=/etc/systemd/system/github-webhook.service
cat > "$unit" <<UNIT
[Unit]
Description=GitHub webhook deploy server
After=network.target

[Service]
User=$GIT_USER
Group=$GIT_USER
WorkingDirectory=$base
ExecStart=$bun_bin $base/bin/server.ts
Environment=PORT=$port
Environment=GITHUB_WEBHOOK_ROOT=$base
Environment=HOME=$GIT_HOME
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$base
PrivateTmp=false

[Install]
WantedBy=multi-user.target
UNIT
chmod 644 "$unit"
systemctl daemon-reload
systemctl enable --now github-webhook.service
systemctl --no-pager status github-webhook.service || true

printf '\nServer installed and running on port %s. If GitHub cannot reach it, open the port:\n' "$port"
printf '  sudo ufw allow %s/tcp comment github-webhook\n' "$port"
printf 'or put a reverse proxy in front of 127.0.0.1:%s.\n' "$port"
