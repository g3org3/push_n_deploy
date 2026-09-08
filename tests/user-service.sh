#!/usr/bin/env bash
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
verifier=$(command -v systemd-analyze || true)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/bin"
export XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data with spaces"
export SERVICE_TEST_LOG="$tmp/calls" SERVICE_LINGER_STATE="$tmp/linger"
cat > "$tmp/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >> "$SERVICE_TEST_LOG"
case $2 in
  show-environment) [[ ${SERVICE_NO_BUS:-0} == 0 ]] ;;
  show) printf '%s' "${SERVICE_EXISTING_FRAGMENT:-}" ;;
esac
SH
cat > "$tmp/bin/loginctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'loginctl %s\n' "$*" >> "$SERVICE_TEST_LOG"
if [[ $1 == show-user ]]; then
  if [[ -f $SERVICE_LINGER_STATE ]]; then printf 'yes\n'; else printf 'no\n'; fi
else
  [[ ${SERVICE_LINGER_DENIED:-0} == 0 ]] || exit 1
  touch "$SERVICE_LINGER_STATE"
fi
SH
cat > "$tmp/bin/sudo" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$tmp/bin/systemd-analyze" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify %s\n' "$*" >> "$SERVICE_TEST_LOG"
[[ ${SERVICE_INVALID_UNIT:-0} == 0 ]]
SH
cat > "$tmp/bin/mise" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'mise %s\n' "$*" >> "$SERVICE_TEST_LOG"
if [[ $1 == exec ]]; then
  shift 2
  export MISE_RUNTIME=ready
  exec "$@"
fi
SH
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
destination="$tmp/application with 'quotes' and 100%"
installer="$tmp/install-user-service.sh"
cat "$project/scripts/lib/mise.sh" "$project/scripts/lib/install-user-service.sh" > "$installer"
bash "$installer" george/myapp "$destination" george.myapp.service on-failure yes > "$tmp/output"
unit="$XDG_CONFIG_HOME/systemd/user/george.myapp.service"
runner="$XDG_DATA_HOME/push-n-deploy/george.myapp/run"
[[ -f $unit && -f $runner && -f $SERVICE_LINGER_STATE ]] || fail 'Service files or lingering were not installed.'
grep -q 'Restart=on-failure' "$unit" || fail 'Restart policy missing.'
grep -q '100%%/current' "$unit" || fail 'Systemd path specifier was not escaped.'
grep -q 'systemctl --user daemon-reload' "$SERVICE_TEST_LOG" || fail 'Manager was not reloaded.'
grep -q 'systemctl --user enable george.myapp.service' "$SERVICE_TEST_LOG" || fail 'Service was not enabled.'
grep -q 'mise --version' "$SERVICE_TEST_LOG" || fail 'Service setup did not ensure mise is available.'
if grep -q 'systemctl --user restart' "$SERVICE_TEST_LOG"; then fail 'Installer started service before deployment.'; fi
mkdir -p "$destination/current"
cat > "$destination/current/Makefile" <<'MAKE'
.PHONY: run
run:
	@printf '%s\n' "$${MISE_RUNTIME:-plain}" > run-result
MAKE
(cd "$destination/current" && bash "$runner")
[[ $(cat "$destination/current/run-result") == plain ]] || fail 'Service did not execute make run without mise config.'
printf '[tools]\n' > "$destination/current/mise.toml"
(cd "$destination/current" && bash "$runner")
[[ $(cat "$destination/current/run-result") == ready ]] || fail 'Service did not execute make run in the mise environment.'
grep -q 'mise exec -- make run' "$SERVICE_TEST_LOG" || fail 'Service used the wrong mise command.'
if [[ -n $verifier ]]; then
  if ! SYSTEMD_LOG_TARGET=console SYSTEMD_LOG_LEVEL=err "$verifier" verify "$unit" > "$tmp/verify.log" 2>&1; then
    cat "$tmp/verify.log" >&2
    fail 'Real systemd unit verification failed.'
  fi
fi
# An existing managed service can be updated without taking it down.
bash "$installer" george/myapp "$destination" george.myapp.service always no > "$tmp/output"
grep -q 'Restart=always' "$unit" || fail 'Managed service was not updated.'
before=$(cat "$unit")
if bash "$installer" other/myapp "$destination" george.myapp.service on-failure no > "$tmp/output" 2>&1; then
  fail 'Installer replaced an unrelated service.'
fi
[[ $(cat "$unit") == "$before" ]] || fail 'Unrelated-service check changed the unit.'
export SERVICE_INVALID_UNIT=1
if bash "$installer" george/myapp "$destination" george.myapp.service no no > "$tmp/output" 2>&1; then
  fail 'Installer accepted a failed unit verification.'
fi
[[ $(cat "$unit") == "$before" ]] || fail 'Failed verification replaced the existing unit.'
unset SERVICE_INVALID_UNIT
export SERVICE_NO_BUS=1
if bash "$installer" george/myapp "$destination" another.service on-failure no > "$tmp/output" 2>&1; then
  fail 'Installer ignored an unavailable user manager.'
fi
[[ ! -f $XDG_CONFIG_HOME/systemd/user/another.service ]] || fail 'Unavailable manager left a unit installed.'
unset SERVICE_NO_BUS
rm "$SERVICE_LINGER_STATE"
export SERVICE_LINGER_DENIED=1
if bash "$installer" george/myapp "$destination" another.service on-failure yes > "$tmp/output" 2>&1; then
  fail 'Installer ignored missing lingering permissions.'
fi
grep -q 'sudo loginctl enable-linger' "$tmp/output" || fail 'Missing actionable lingering instructions.'
printf 'User service tests passed.\n'
