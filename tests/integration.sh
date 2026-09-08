#!/usr/bin/env bash
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/bin" "$tmp/config"
# Execute the SSH command locally while retaining the real archive stream.
cat > "$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$SSH_ARGS_LOG"
[[ ${SSH_FAIL:-0} == 0 ]] || exit 255
cat > "$ARTIFACT_LOG"
gzip -t "$ARTIFACT_LOG"
export PATH="$TEST_TOOLS_BIN:$PATH"
exec bash -c "${!#}" < "$ARTIFACT_LOG"
SH
chmod +x "$tmp/bin/ssh"
export PATH="$tmp/bin:$PATH" SSH_ARGS_LOG="$tmp/ssh-args"
export ARTIFACT_LOG="$tmp/artifact.tar.gz"
export TEST_TOOLS_BIN="$tmp/bin"
export TEST_GIT_HOME="$tmp/git-home"
mkdir -p "$TEST_GIT_HOME/george"
repo="$TEST_GIT_HOME/george/myapp"
git init -q --bare --initial-branch=main "$repo"
# Model SSH starting git-shell in the Git account's home directory.
cat > "$tmp/bin/git-ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cd -- "$TEST_GIT_HOME"
exec git-shell -c "${!#}"
SH
chmod +x "$tmp/bin/git-ssh"
export GIT_SSH_COMMAND="$tmp/bin/git-ssh" GIT_SSH_VARIANT=ssh
git init -q --initial-branch=main "$tmp/work"
git -C "$tmp/work" config user.name 'Deployment Test'
git -C "$tmp/work" config user.email 'test@example.invalid'
git -C "$tmp/work" remote add deploy git@example.invalid:george/myapp
config_dir="$tmp/config"
builds_dir="$TEST_GIT_HOME/.push_n_deploy/george/myapp"
mkdir -p "$builds_dir"
destination="$tmp/target with spaces and ' quote"
printf 'target=%q\ndestination=%q\nbranch=main\nport=2222\n' 'deploy@example.invalid' "$destination" > "$config_dir/config"
cat "$project/scripts/lib/mise.sh" "$project/scripts/lib/releases.sh" "$project/scripts/lib/remote-deploy.sh" > "$config_dir/remote-deploy.sh"
cp "$project/scripts/lib/prepare-artifact.sh" "$config_dir/prepare-artifact.sh"
touch "$config_dir/lock"
{
  printf '#!/usr/bin/env bash\nconfig_dir=%q\nbuilds_dir=%q\n' "$config_dir" "$builds_dir"
  cat "$project/scripts/lib/post-receive.sh"
} > "$repo/hooks/post-receive"
chmod +x "$repo/hooks/post-receive"
printf 'deploy:\n\t@test "$$(cat version)" = one\n\t@printf "%%s\\n" "$$PUSH_DEPLOY_REVISION" > deployed\n' > "$tmp/work/Makefile"
printf 'one\n' > "$tmp/work/version"
git -C "$tmp/work" add .
git -C "$tmp/work" commit -qm initial
git -C "$tmp/work" push deploy main > "$tmp/push.log" 2>&1
revision=$(git -C "$tmp/work" rev-parse HEAD)
[[ $(cat "$destination/current/deployed") == "$revision" ]] || fail 'Exact pushed revision was not deployed.'
[[ $(cat "$destination/current/version") == one ]] || fail 'Archive was not extracted.'
grep -q 'StrictHostKeyChecking=yes' "$SSH_ARGS_LOG" || fail 'SSH host verification missing.'
grep -q 'BatchMode=yes' "$SSH_ARGS_LOG" || fail 'Noninteractive SSH missing.'
first=$(readlink "$destination/current")
rm "$SSH_ARGS_LOG"
git -C "$tmp/work" push deploy HEAD:refs/heads/feature > "$tmp/push.log" 2>&1
git -C "$tmp/work" tag v1
git -C "$tmp/work" push deploy v1 > "$tmp/push.log" 2>&1
[[ ! -e $SSH_ARGS_LOG ]] || fail 'Other branches or tags deployed.'
# A failing make must be visible while leaving current at its last success.
printf 'deploy:\n\t@exit 1\n' > "$tmp/work/Makefile"
git -C "$tmp/work" commit -qam failure
git -C "$tmp/work" push deploy main > "$tmp/push.log" 2>&1
grep -q 'DEPLOYMENT FAILED' "$tmp/push.log" || fail 'Failure was not reported.'
[[ $(readlink "$destination/current") == "$first" ]] || fail 'Failed release replaced current.'
[[ $(git --git-dir="$repo" rev-parse main) == "$(git -C "$tmp/work" rev-parse HEAD)" ]] || fail 'Push should remain accepted after hook failure.'
rm "$SSH_ARGS_LOG"
# A stale queued invocation and a deletion should do no work.
printf '%s %s refs/heads/main\n' "$revision" "$revision" | (cd "$repo" && hooks/post-receive)
printf '%s %040d refs/heads/main\n' "$revision" 0 | (cd "$repo" && hooks/post-receive)
[[ ! -e $SSH_ARGS_LOG ]] || fail 'Stale or deletion hook deployed.'
# SSH connection failure also must be surfaced.
export SSH_FAIL=1
git -C "$tmp/work" commit --allow-empty -qm connection-failure
git -C "$tmp/work" push deploy main > "$tmp/push.log" 2>&1
grep -q 'DEPLOYMENT FAILED' "$tmp/push.log" || fail 'SSH failure was not reported.'
[[ $(readlink "$destination/current") == "$first" ]] || fail 'SSH failure replaced current.'
ssh_failed_revision=$(git -C "$tmp/work" rev-parse HEAD)
retained=("$builds_dir/"*"-$ssh_failed_revision-"*.tar.gz)
[[ ${#retained[@]} -eq 1 && -f ${retained[0]} ]] || fail 'SSH failure lost the completed artifact.'
gzip -t "${retained[0]}"
# Recovery creates a clean release and advances current only on success.
unset SSH_FAIL
git -C "$tmp/work" rm -q version
printf 'deploy:\n\t@test ! -e version\n\t@printf "%%s\\n" "$$PUSH_DEPLOY_REVISION" > deployed\n' > "$tmp/work/Makefile"
git -C "$tmp/work" commit -qam recovery
git -C "$tmp/work" push deploy main > "$tmp/push.log" 2>&1
[[ $(readlink "$destination/current") != "$first" ]] || fail 'Recovery did not advance current.'
[[ $(cat "$destination/current/deployed") == "$(git -C "$tmp/work" rev-parse HEAD)" ]] || fail 'Recovery deployed the wrong revision.'
[[ ! -e $destination/current/version ]] || fail 'Deleted source files survived into the release.'

# Build locally and ship only default dist/ plus Makefile, including hidden output.
printf 'source only\n' > "$tmp/work/source.txt"
cat > "$tmp/work/Makefile" <<'MAKE'
.PHONY: build deploy
build:
	@test -z "$$GIT_DIR"
	@mkdir -p dist
	@printf '%s\n' "$$PUSH_DEPLOY_REVISION" > dist/revision
	@printf 'hidden\n' > dist/.hidden
deploy:
	@test ! -e source.txt
	@test -f dist/.hidden
	@test "$$(cat dist/revision)" = "$$PUSH_DEPLOY_REVISION"
	@cp dist/revision deployed
MAKE
git -C "$tmp/work" add .
git -C "$tmp/work" commit -qm default-build
git -C "$tmp/work" push deploy main > "$tmp/push.log" 2>&1
grep -q 'Building .* on the Git server' "$tmp/push.log" || fail 'Build did not run.'
[[ $(cat "$destination/current/deployed") == "$(git -C "$tmp/work" rev-parse HEAD)" ]] || fail 'Built artifact was not deployed.'
[[ ! -e $destination/current/source.txt ]] || fail 'Artifact included source outside dist.'

# Custom quoted output, with build defined in an included file via a variable.
export MISE_CALL_LOG="$tmp/mise-calls"
cat > "$tmp/bin/mise" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MISE_CALL_LOG"
case $1 in
  --version) printf 'mise test\n' ;;
  trust) [[ -f $2 ]] ;;
  install) [[ ${MISE_INSTALL_FAIL:-0} == 0 ]] ;;
  exec) shift 2; exec "$@" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/mise"
printf '[tools]\npython = "3.12"\n' > "$tmp/work/mise.toml"
printf '# artifact location\noutput_dir: "./build output" # comment\n' > "$tmp/work/.push_n_deploy.yml"
cat > "$tmp/work/Makefile" <<'MAKE'
-include build.mk
.PHONY: deploy
deploy:
	@test ! -e source.txt
	@test ! -e build.mk
	@test ! -e .push_n_deploy.yml
	@test -f mise.toml
	@cp 'build output/revision' deployed
MAKE
cat > "$tmp/work/build.mk" <<'MAKE'
TARGET := build
.PHONY: $(TARGET)
$(TARGET):
	@mkdir -p 'build output'
	@printf '%s\n' "$$PUSH_DEPLOY_REVISION" > 'build output/revision'
MAKE
git -C "$tmp/work" add .
git -C "$tmp/work" commit -qm custom-build
git -C "$tmp/work" push deploy main > "$tmp/push.log" 2>&1
[[ $(cat "$destination/current/deployed") == "$(git -C "$tmp/work" rev-parse HEAD)" ]] || fail 'Custom artifact was not deployed.'
cmp "$tmp/work/mise.toml" "$destination/current/mise.toml" || fail 'Artifact lost mise.toml.'
expected_mise_calls=$'--version\ntrust ./mise.toml\ninstall\nexec -- make deploy'
[[ $(cat "$MISE_CALL_LOG") == "$expected_mise_calls" ]] || fail 'Target runtime preparation order is incorrect.'
last_success=$(readlink "$destination/current")
artifacts_before_failure=$(printf '%s\n' "$builds_dir"/*.tar.gz)

assert_local_failure() {
  rm -f "$SSH_ARGS_LOG"
  git -C "$tmp/work" add -A
  git -C "$tmp/work" commit -qm "$1"
  git -C "$tmp/work" push deploy main > "$tmp/push.log" 2>&1
  grep -q 'DEPLOYMENT FAILED' "$tmp/push.log" || fail "$1 was not reported."
  [[ ! -e $SSH_ARGS_LOG ]] || fail "$1 reached SSH instead of stopping locally."
  [[ $(readlink "$destination/current") == "$last_success" ]] || fail "$1 changed current."
  [[ $(printf '%s\n' "$builds_dir"/*.tar.gz) == "$artifacts_before_failure" ]] || fail "$1 changed retained artifacts."
}
printf 'build:\n\t@exit 1\n' > "$tmp/work/build.mk"
assert_local_failure build-failure
printf 'build:\n\t@true\n' > "$tmp/work/build.mk"
assert_local_failure missing-output
printf 'build: missing-prerequisite\n' > "$tmp/work/build.mk"
assert_local_failure broken-build-prerequisite
printf 'build:\n\t@true\n' > "$tmp/work/build.mk"
for invalid in '../escape' '.' '/tmp' "'../escape'" '[]'; do
  printf 'output_dir: %s\n' "$invalid" > "$tmp/work/.push_n_deploy.yml"
  assert_local_failure "invalid-output-$invalid"
done
printf 'output_dir: ./dist\n' > "$tmp/work/.push_n_deploy.yml"
printf 'build:\n\t@ln -s /tmp dist\n' > "$tmp/work/build.mk"
assert_local_failure symlink-output

# A directory called build alone is not a Make target; source fallback still works.
git -C "$tmp/work" rm -q build.mk
mkdir -p "$tmp/work/build"
touch "$tmp/work/build/source"
printf 'deploy:\n\t@test -f source.txt\n\t@test -f build/source\n\t@printf "%%s\\n" "$$PUSH_DEPLOY_REVISION" > deployed\n' > "$tmp/work/Makefile"
git -C "$tmp/work" add -A
git -C "$tmp/work" commit -qm source-fallback
git -C "$tmp/work" push deploy main > "$tmp/push.log" 2>&1
[[ $(cat "$destination/current/deployed") == "$(git -C "$tmp/work" rev-parse HEAD)" ]] || fail 'Source fallback failed after artifact deployment.'

# Retention is per repository and keeps exactly the latest three completed bundles.
other_builds="$TEST_GIT_HOME/.push_n_deploy/other/myapp"
mkdir -p "$other_builds"
touch "$other_builds/keep.tar.gz" "$builds_dir/keep.txt"
revisions=()
for number in 1 2 3 4; do
  git -C "$tmp/work" commit --allow-empty -qm "retention-$number"
  revisions+=("$(git -C "$tmp/work" rev-parse HEAD)")
  git -C "$tmp/work" push deploy main > "$tmp/push.log" 2>&1
done
retained=("$builds_dir"/*.tar.gz)
[[ ${#retained[@]} -eq 3 ]] || fail 'Retention did not keep exactly three artifacts.'
for index in 0 1 2; do
  [[ ${retained[index]} == *"-${revisions[index+1]}-"* ]] || fail 'Retention kept the wrong revision.'
  gzip -t "${retained[index]}"
  tar -tzf "${retained[index]}" | grep -qx Makefile || fail 'Retained artifact is missing its Makefile.'
done
[[ -f $other_builds/keep.tar.gz && -f $builds_dir/keep.txt ]] || fail 'Retention touched unrelated files.'
shopt -s nullglob
staging=("$builds_dir"/.artifact.*)
[[ ${#staging[@]} -eq 0 ]] || fail 'Artifact staging files were not cleaned up.'

# Optional service restarts occur only after make deploy and the current switch.
export SERVICE_RESTART_LOG="$tmp/service-calls" SERVICE_CURRENT="$destination/current"
cat > "$tmp/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SERVICE_RESTART_LOG"
[[ $1 == --user ]] || exit 1
[[ -n $XDG_RUNTIME_DIR && -n $DBUS_SESSION_BUS_ADDRESS ]] || exit 1
case $2 in
  restart)
    [[ $(cat "$SERVICE_CURRENT/deployed") == "$PUSH_DEPLOY_REVISION" ]] || exit 1
    [[ ${SERVICE_RESTART_FAIL:-0} == 0 ]] ;;
  is-active) [[ ${SERVICE_INACTIVE:-0} == 0 ]] ;;
  status) exit 3 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/systemctl"
printf 'george.myapp.service\n' > "$config_dir/service"
git -C "$tmp/work" commit --allow-empty -qm service-enabled
git -C "$tmp/work" push deploy main > "$tmp/push.log" 2>&1
grep -q 'Deployment succeeded' "$tmp/push.log" || fail 'Deployment with service failed.'
grep -qx -- '--user restart george.myapp.service' "$SERVICE_RESTART_LOG" || fail 'Service did not restart.'
grep -qx -- '--user is-active --quiet george.myapp.service' "$SERVICE_RESTART_LOG" || fail 'Service state was not checked.'
service_calls=$(cat "$SERVICE_RESTART_LOG")
last_success=$(readlink "$destination/current")
cp "$tmp/work/Makefile" "$tmp/good-Makefile"
printf 'deploy:\n\t@exit 1\n' > "$tmp/work/Makefile"
git -C "$tmp/work" commit -qam service-make-failure
git -C "$tmp/work" push deploy main > "$tmp/push.log" 2>&1
[[ $(cat "$SERVICE_RESTART_LOG") == "$service_calls" ]] || fail 'Failed make restarted the service.'
[[ $(readlink "$destination/current") == "$last_success" ]] || fail 'Failed make switched current with a service configured.'
cp "$tmp/good-Makefile" "$tmp/work/Makefile"
export SERVICE_RESTART_FAIL=1
git -C "$tmp/work" commit -qam service-restart-failure
git -C "$tmp/work" push deploy main > "$tmp/push.log" 2>&1
grep -q 'DEPLOYMENT FAILED' "$tmp/push.log" || fail 'Service restart failure was not reported.'
grep -q 'current points to the new release' "$tmp/push.log" || fail 'Restart failure did not explain current state.'
[[ $(cat "$destination/current/deployed") == "$(git -C "$tmp/work" rev-parse HEAD)" ]] || fail 'Restart failure unexpectedly rolled back current.'
unset SERVICE_RESTART_FAIL
export SERVICE_INACTIVE=1
git -C "$tmp/work" commit --allow-empty -qm service-inactive
git -C "$tmp/work" push deploy main > "$tmp/push.log" 2>&1
grep -q 'DEPLOYMENT FAILED' "$tmp/push.log" || fail 'Inactive service was treated as successful.'
unset SERVICE_INACTIVE
service_calls=$(cat "$SERVICE_RESTART_LOG")
last_success=$(readlink "$destination/current")
export MISE_INSTALL_FAIL=1
git -C "$tmp/work" commit --allow-empty -qm runtime-install-failure
git -C "$tmp/work" push deploy main > "$tmp/push.log" 2>&1
grep -q 'DEPLOYMENT FAILED' "$tmp/push.log" || fail 'Runtime install failure was not reported.'
[[ $(readlink "$destination/current") == "$last_success" ]] || fail 'Failed runtime install switched current.'
[[ $(cat "$SERVICE_RESTART_LOG") == "$service_calls" ]] || fail 'Failed runtime install restarted the service.'
printf 'Integration tests passed.\n'
