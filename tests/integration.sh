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
exec bash -c "${!#}" < "$ARTIFACT_LOG"
SH
chmod +x "$tmp/bin/ssh"
export PATH="$tmp/bin:$PATH" SSH_ARGS_LOG="$tmp/ssh-args"
export ARTIFACT_LOG="$tmp/artifact.tar.gz"
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
destination="$tmp/target with spaces and ' quote"
printf 'target=%q\ndestination=%q\nbranch=main\nport=2222\n' 'deploy@example.invalid' "$destination" > "$config_dir/config"
cp "$project/scripts/lib/remote-deploy.sh" "$config_dir/remote-deploy.sh"
cp "$project/scripts/lib/prepare-artifact.sh" "$config_dir/prepare-artifact.sh"
touch "$config_dir/lock"
{
  printf '#!/usr/bin/env bash\nconfig_dir=%q\n' "$config_dir"
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
printf '# artifact location\noutput_dir: "./build output" # comment\n' > "$tmp/work/.push_n_deploy.yml"
cat > "$tmp/work/Makefile" <<'MAKE'
-include build.mk
.PHONY: deploy
deploy:
	@test ! -e source.txt
	@test ! -e build.mk
	@test ! -e .push_n_deploy.yml
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
last_success=$(readlink "$destination/current")

assert_local_failure() {
  rm -f "$SSH_ARGS_LOG"
  git -C "$tmp/work" add -A
  git -C "$tmp/work" commit -qm "$1"
  git -C "$tmp/work" push deploy main > "$tmp/push.log" 2>&1
  grep -q 'DEPLOYMENT FAILED' "$tmp/push.log" || fail "$1 was not reported."
  [[ ! -e $SSH_ARGS_LOG ]] || fail "$1 reached SSH instead of stopping locally."
  [[ $(readlink "$destination/current") == "$last_success" ]] || fail "$1 changed current."
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
printf 'Integration tests passed.\n'
