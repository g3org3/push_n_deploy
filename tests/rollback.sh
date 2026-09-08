#!/usr/bin/env bash
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/bin" "$tmp/source"
destination="$tmp/target with spaces and ' quote"
export DEPLOY_LOG="$tmp/deploy.log" SERVICE_LOG="$tmp/service.log" SERVICE_CURRENT="$destination/current" TARGET_LOCK="$destination/.deploy.lock"
cat > "$tmp/bin/mise" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case $1 in
  --version|trust) ;;
  install) [[ ${RUNTIME_FAIL:-0} == 0 ]] ;;
  exec) shift 2; exec "$@" ;;
  *) exit 1 ;;
esac
SH
cat > "$tmp/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SERVICE_LOG"
case $2 in
  restart)
    [[ $(cat "$SERVICE_CURRENT/deployed") == "$PUSH_DEPLOY_REVISION" ]]
    [[ ${SERVICE_FAIL:-0} == 0 ]] ;;
  is-active) ;;
  status) exit 3 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
for action in deploy rollback; do
  cat "$project/scripts/lib/mise.sh" "$project/scripts/lib/releases.sh" "$project/scripts/lib/remote-$action.sh" > "$tmp/$action.sh"
done
cat > "$tmp/source/Makefile" <<'MAKE'
.PHONY: deploy
deploy:
	@test "$${MAKE_FAIL:-0}" = 0
	@! flock -n "$$TARGET_LOCK" true
	@printf '%s\n' "$$PUSH_DEPLOY_REVISION" > deployed
	@printf '%s\n' "$$PUSH_DEPLOY_REVISION" >> "$$DEPLOY_LOG"
MAKE
printf '[tools]\npython = "3.12"\n' > "$tmp/source/mise.toml"
tar -czf "$tmp/artifact.tar.gz" -C "$tmp/source" .
deploy() { bash "$tmp/deploy.sh" "$destination" "$1" test.service < "$tmp/artifact.tar.gz" > "$tmp/output" 2>&1; }
rollback() { bash "$tmp/rollback.sh" "$destination" test.service > "$tmp/output" 2>&1; }
revision1=$(printf '%040x' 1)
revision2=$(printf '%040x' 2)
revision3=$(printf '%040x' 3)
deploy "$revision1"
first=$(readlink "$destination/current")
if rollback; then fail 'Rollback succeeded with no previous release.'; fi
[[ $(readlink "$destination/current") == "$first" ]] || fail 'No-previous rollback changed current.'
deploy "$revision2"
second=$(readlink "$destination/current")
export SERVICE_FAIL=1
if deploy "$revision3"; then fail 'Expected failed third deployment.'; fi
unset SERVICE_FAIL
failed_current=$(readlink "$destination/current")
history_before=$(cat "$destination/.push-n-deploy-history")
service_before=$(cat "$SERVICE_LOG")
export MAKE_FAIL=1
if rollback; then fail 'Rollback ignored Make failure.'; fi
unset MAKE_FAIL
[[ $(readlink "$destination/current") == "$failed_current" && $(cat "$SERVICE_LOG") == "$service_before" ]] || fail 'Failed rollback Make changed current or restarted service.'
[[ $(cat "$destination/.push-n-deploy-history") == "$history_before" ]] || fail 'Failed rollback changed history.'
export RUNTIME_FAIL=1
if rollback; then fail 'Rollback ignored runtime installation failure.'; fi
unset RUNTIME_FAIL
[[ $(readlink "$destination/current") == "$failed_current" ]] || fail 'Failed rollback runtime install changed current.'
rollback
[[ $(readlink "$destination/current") == "$second" ]] || fail 'Rollback did not recover the last success after service failure.'
[[ $(tail -n 1 "$DEPLOY_LOG") == "$revision2" ]] || fail 'Rollback did not rerun Make with the old revision.'
rollback
[[ $(readlink "$destination/current") == "$first" ]] || fail 'Repeated rollback did not step backward.'
if rollback; then fail 'Rollback toggled forward after history was exhausted.'; fi

# Deleted old releases are skipped, and service failures remain visible.
deploy "$revision2"
second=$(readlink "$destination/current")
deploy "$revision3"
rm -rf -- "$destination/$second"
rollback
[[ $(readlink "$destination/current") == "$first" ]] || fail 'Rollback failed to skip a removed release.'
deploy "$revision2"
export SERVICE_FAIL=1
if rollback; then fail 'Rollback ignored a service restart failure.'; fi
unset SERVICE_FAIL
grep -q 'Service restart failed' "$tmp/output" || fail 'Rollback service failure was not explained.'
[[ $(readlink "$destination/current") == "$first" ]] || fail 'Unexpected current state after rollback restart failure.'

# Historical directories without success metadata are never guessed from mtimes.
mv "$destination/.push-n-deploy-history" "$tmp/history"
if rollback; then fail 'Rollback guessed an untracked release.'; fi
grep -q 'No successful-release history' "$tmp/output" || fail 'Missing upgrade guidance for old deployments.'
printf '../outside\n' > "$destination/.push-n-deploy-history"
if rollback; then fail 'Rollback accepted an unsafe history entry.'; fi
[[ $(readlink "$destination/current") == "$first" ]] || fail 'Invalid history changed current.'
printf 'Rollback tests passed.\n'
