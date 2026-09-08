#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $# -eq 5 ]] || { printf 'Expected repository, directory, service, restart policy and lingering option.\n' >&2; exit 1; }
repo=$1 destination=$2 service=$3 restart_policy=$4 linger=$5
die() { printf 'Service setup error: %s\n' "$*" >&2; exit 1; }
[[ $repo =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*/[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || die 'Invalid repository name.'
[[ $service =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*\.service$ ]] || die 'Invalid service name.'
[[ $destination == /* && $destination != / && $destination != *$'\n'* && $destination != *$'\r'* ]] || die 'Invalid application directory.'
[[ $restart_policy == on-failure || $restart_policy == always || $restart_policy == no ]] || die 'Invalid restart policy.'
[[ $linger == yes || $linger == no ]] || die 'Invalid lingering option.'
for executable in systemctl systemd-analyze; do
  command -v "$executable" >/dev/null || die "Install target dependencies first: missing $executable."
done
mkdir -p -- "$destination"
exec 8>"$destination/.deploy.lock"
flock 8
if [[ $linger == yes ]]; then
  command -v loginctl >/dev/null || die 'loginctl is missing; install target dependencies.'
  account=$(id -un)
  if [[ $(loginctl show-user "$account" -p Linger --value 2>/dev/null || true) != yes ]]; then
    if ! loginctl --no-ask-password enable-linger "$account"; then
      if ! command -v sudo >/dev/null || ! sudo -n loginctl enable-linger "$account"; then
        die "On the target, an administrator must run: sudo loginctl enable-linger $account. Then rerun service setup."
      fi
    fi
  fi
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
systemctl --user show-environment >/dev/null || die 'Cannot reach the systemd user manager. Ensure systemd, libpam-systemd and dbus-user-session are installed, enable lingering if needed, then reconnect SSH.'

unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
runner_dir="${XDG_DATA_HOME:-$HOME/.local/share}/push-n-deploy/${service%.service}"
[[ $unit_dir == /* && $runner_dir == /* && $unit_dir != *$'\n'* && $runner_dir != *$'\n'* && $runner_dir != *$'\r'* ]] || die 'XDG config/data directories must be absolute paths without line breaks.'
marker="# Managed by push-n-deploy: $repo"
existing_fragment=$(systemctl --user show "$service" -p FragmentPath --value 2>/dev/null || true)
[[ -z $existing_fragment || $existing_fragment == "$unit_dir/$service" ]] || die "Refusing to shadow an existing service at $existing_fragment."
if [[ -e $unit_dir/$service || -L $unit_dir/$service ]]; then
  [[ -f $unit_dir/$service && ! -L $unit_dir/$service ]] || die 'Refusing to replace a non-regular unit file.'
  IFS= read -r existing_marker < "$unit_dir/$service" || true
  [[ $existing_marker == "$marker" ]] || die "Refusing to overwrite an unrelated service: $service"
fi
if [[ -e $runner_dir || -L $runner_dir ]]; then
  [[ -d $runner_dir && ! -L $runner_dir && -f $runner_dir/owner ]] || die 'Refusing to overwrite an unrelated runner directory.'
  [[ $(cat "$runner_dir/owner") == "$repo" ]] || die 'Runner belongs to another repository.'
fi
staging=$(mktemp -d)
trap 'rm -rf -- "$staging"' EXIT
# Resolve mise once so the service uses the same executable that setup verified.
ensure_mise
mise_executable=$(command -v mise)
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  printf 'export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"\n'
  printf 'if [[ -f mise.toml ]]; then\n'
  printf '  exec %q exec -- make run\n' "$mise_executable"
  printf 'else\n  exec make run\nfi\n'
} > "$staging/run"
bash -n "$staging/run"
unit_quote() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//%/%%}
  value=${value//$'\t'/\\t}
  printf '"%s"' "$value"
}
{
  printf '%s\n[Unit]\nDescription=Push and deploy: %s\n\n[Service]\nType=exec\n' "$marker" "$repo"
  # WorkingDirectory takes the whole value literally (unlike ExecStart arguments).
  working_directory=${destination%/}
  printf 'WorkingDirectory=%s/current\n' "${working_directory//%/%%}"
  exec_path="${runner_dir//\$/\$\$}/run"
  printf 'ExecStart=/bin/bash %s\n' "$(unit_quote "$exec_path")"
  printf 'Restart=%s\nRestartSec=3\nTimeoutStopSec=30\n\n[Install]\nWantedBy=default.target\n' "$restart_policy"
} > "$staging/$service"
systemd-analyze --user verify "$staging/$service"
mkdir -p -- "$unit_dir" "$runner_dir"
printf '%s\n' "$repo" > "$runner_dir/owner"
# Publish each file with a same-directory rename so systemd never reads a partial file.
runner_tmp=$(mktemp "$runner_dir/.run.XXXXXXXX")
unit_tmp=$(mktemp "$unit_dir/.unit.XXXXXXXX")
trap 'rm -rf -- "$staging"; rm -f -- "$runner_tmp" "$unit_tmp"' EXIT
cat "$staging/run" > "$runner_tmp"
chmod 700 "$runner_tmp"
mv -f -- "$runner_tmp" "$runner_dir/run"
cat "$staging/$service" > "$unit_tmp"
chmod 644 "$unit_tmp"
mv -f -- "$unit_tmp" "$unit_dir/$service"
systemctl --user daemon-reload
systemctl --user enable "$service"
printf 'Installed %s for target user %s.\n' "$unit_dir/$service" "$(id -un)"
