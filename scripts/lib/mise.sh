#!/usr/bin/env bash

ensure_mise() {
  local install_path=${1:-$HOME/.local/bin/mise}
  if ! command -v mise >/dev/null; then
    export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
  fi
  if ! command -v mise >/dev/null; then
    command -v curl >/dev/null || { printf 'curl is missing; run install-dependencies.sh target on this machine.\n' >&2; return 1; }
    mkdir -p -- "${install_path%/*}"
    printf 'Installing mise for target user %s.\n' "$(id -un)"
    curl -fsSL https://mise.run | MISE_INSTALL_PATH="$install_path" sh || return
    export PATH="${install_path%/*}:$PATH"
  fi
  mise --version
}
