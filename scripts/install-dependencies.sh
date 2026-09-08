#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
root_required
[[ $# -le 1 ]] || die 'Usage: install-dependencies.sh [git-server|target]'
role=${1:-git-server}
[[ $role == git-server || $role == target ]] || die 'Role must be git-server or target.'
command -v apt-get >/dev/null || die 'This installer supports Debian/Ubuntu. See README for packages on other systems.'
packages=(bash openssh-server tar gzip make mawk util-linux coreutils curl ca-certificates)
[[ $role != git-server ]] || packages+=(git openssh-client passwd)
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
# Install system-wide so the deploy account can use mise over SSH.
if [[ ! -x /usr/local/bin/mise ]]; then
  install -d -m 755 /usr/local/bin
  curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh
fi
/usr/local/bin/mise --version
printf 'Dependencies installed. Ensure the SSH service is running and reachable.\n'
