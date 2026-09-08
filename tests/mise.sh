#!/usr/bin/env bash
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export TEST_INSTALL_PATH="$tmp/local/bin/mise" TEST_MISE_LOG="$tmp/calls"
# Model the official installer without downloading or touching the user's home.
cat > "$tmp/harness.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$1/scripts/lib/mise.sh"
command() {
  if [[ $* == '-v mise' ]]; then
    [[ -x $TEST_INSTALL_PATH ]] || return 1
    printf '%s\n' "$TEST_INSTALL_PATH"
  else
    builtin command "$@"
  fi
}
curl() {
  printf 'download\n' >> "$TEST_MISE_LOG"
  [[ ${DOWNLOAD_FAIL:-0} == 0 ]] || return 22
  cat <<'INSTALL'
set -eu
cat > "$MISE_INSTALL_PATH" <<'TOOL'
#!/usr/bin/env bash
printf 'mise %s\n' "$*" >> "$TEST_MISE_LOG"
TOOL
chmod +x "$MISE_INSTALL_PATH"
INSTALL
}
mise() { "$TEST_INSTALL_PATH" "$@"; }
ensure_mise "$TEST_INSTALL_PATH"
SH
bash "$tmp/harness.sh" "$project"
bash "$tmp/harness.sh" "$project"
[[ $(cat "$TEST_MISE_LOG") == $'download\nmise --version\nmise --version' ]] || { printf 'Unexpected installation/reuse behavior.\n' >&2; exit 1; }
export TEST_INSTALL_PATH="$tmp/failure/bin/mise" DOWNLOAD_FAIL=1
if bash "$tmp/harness.sh" "$project"; then
  printf 'Installer download failure was ignored.\n' >&2
  exit 1
fi
[[ ! -e $TEST_INSTALL_PATH ]] || exit 1
printf 'Mise installation tests passed.\n'
