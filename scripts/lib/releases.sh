#!/usr/bin/env bash

release_error() { printf 'Release error: %s\n' "$*" >&2; exit 1; }
valid_release_name() { [[ $1 =~ ^([a-f0-9]{40}|[a-f0-9]{64})\.[a-zA-Z0-9]{8}$ ]]; }
initialize_releases() {
  [[ $destination == /* && $destination != / ]] || release_error 'Invalid target directory.'
  [[ -z $service || $service =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*\.service$ ]] || release_error 'Invalid service name.'
  cd -P -- "$destination"
  destination=$PWD
  exec 8>.deploy.lock
  flock 8
  [[ -d releases && ! -L releases ]] || release_error 'Expected a releases directory, not a symlink.'
  if [[ -e current && ! -L current ]]; then
    release_error 'Refusing to replace current: expected a symlink.'
  fi
  release_history=()
  history_file="$destination/.push-n-deploy-history"
  if [[ -e $history_file || -L $history_file ]]; then
    [[ -f $history_file && ! -L $history_file ]] || release_error 'Invalid release history file.'
    mapfile -t release_history < "$history_file"
    local name
    for name in "${release_history[@]}"; do
      valid_release_name "$name" || release_error 'Invalid release history entry.'
    done
  fi
}
activate_release() {
  local release=$1
  [[ -d $release && ! -L $release && $(realpath -e -- "$release") == "$release" ]] || release_error 'Release directory is missing or resolves through a symlink.'
  activation_dir=$(mktemp -d "$destination/.activation.XXXXXXXX")
  trap 'rm -rf -- "$activation_dir"' EXIT
  cd -- "$release"
  export PUSH_DEPLOY_REVISION="${release##*/}"
  PUSH_DEPLOY_REVISION=${PUSH_DEPLOY_REVISION%%.*}
  if [[ -e mise.toml || -L mise.toml ]]; then
    [[ -f mise.toml && ! -L mise.toml ]] || release_error 'mise.toml must be a regular file.'
    ensure_mise
    mise trust ./mise.toml
    mise install
    mise exec -- make deploy
  else
    make deploy
  fi
  cd -- "$destination"
  ln -s -- "releases/${release##*/}" "$activation_dir/current"
  mv -Tf -- "$activation_dir/current" current
  if [[ -n $service ]]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
    printf 'Restarting user service: %s\n' "$service"
    if ! systemctl --user restart "$service" || ! systemctl --user is-active --quiet "$service"; then
      systemctl --user status --no-pager "$service" >&2 || true
      printf 'Service restart failed: %s. current points to the new release selected for activation; inspect the user journal before retrying.\n' "$service" >&2
      exit 1
    fi
  fi
}
save_release_history() {
  printf '%s\n' "$@" > "$activation_dir/history"
  mv -f -- "$activation_dir/history" "$history_file"
}
