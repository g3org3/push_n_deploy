#!/usr/bin/env bash
set -euo pipefail
umask 022
work_dir=$1
export PUSH_DEPLOY_REVISION=$2
die() { printf 'Artifact error: %s\n' "$*" >&2; exit 1; }
trim() {
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
}
read_output_dir() {
  output_dir=dist
  [[ -e .push_n_deploy.yml ]] || return 0
  [[ -f .push_n_deploy.yml && ! -L .push_n_deploy.yml ]] || die 'Expected a regular .push_n_deploy.yml file.'
  local line value seen=false
  local single="^'([^']*)'[[:blank:]]*(#.*)?$"
  local double='^"([^"\\]*)"[[:blank:]]*(#.*)?$'
  while IFS= read -r line || [[ -n $line ]]; do
    value=$line
    trim
    [[ -z $value || $value == \#* ]] && continue
    [[ $value =~ ^output_dir:[[:blank:]]*(.*)$ ]] || die 'Config supports only a top-level output_dir string.'
    [[ $seen == false ]] || die 'Duplicate output_dir.'
    seen=true
    value=${BASH_REMATCH[1]}
    trim
    case $value in
      \"*) [[ $value =~ $double ]] || die 'Invalid quoted output_dir.'; value=${BASH_REMATCH[1]} ;;
      \'*) [[ $value =~ $single ]] || die 'Invalid quoted output_dir.'; value=${BASH_REMATCH[1]} ;;
      *) value=${value%%#*}; trim ;;
    esac
    [[ -n $value ]] || die 'output_dir must not be empty.'
    output_dir=$value
  done < .push_n_deploy.yml
  output_dir=${output_dir#./}
  output_dir=${output_dir%/}
  [[ $output_dir =~ ^[a-zA-Z0-9_./\ -]+$ && $output_dir != /* ]] || die 'output_dir must be a relative directory using letters, digits, spaces, dots, underscores or hyphens.'
  local component
  local -a components
  IFS=/ read -r -a components <<< "$output_dir"
  for component in "${components[@]}"; do
    [[ -n $component && $component != . && $component != .. ]] || die 'output_dir must stay inside the checkout and cannot be its root.'
  done
}

mkdir "$work_dir/source"
tar -xf "$work_dir/source.tar" -C "$work_dir/source" --no-same-owner --no-same-permissions
cd "$work_dir/source"
makefile=
for candidate in GNUmakefile makefile Makefile; do
  if [[ -f $candidate ]]; then makefile=$candidate; break; fi
done
[[ -n $makefile && ! -L $makefile ]] || die 'A regular Makefile with a deploy target is required.'

# Query Make's parsed target database, including variables and include files.
# An unrelated empty goal avoids running recipes or traversing build prerequisites.
probe=__push_n_deploy_probe_${RANDOM}_${RANDOM}
printf '%s: ;\n' "$probe" > "$work_dir/probe.mk"
status=0
LC_ALL=C make -qp -f "$makefile" -f "$work_dir/probe.mk" "$probe" > "$work_dir/make.db" || status=$?
[[ $status -le 1 ]] || die 'Could not read Makefile targets.'
if ! awk '
  /^# Not a target:/ { not_target=1; next }
  /^build:/ { if (!not_target) found=1 }
  /^[^#[:space:]]/ { not_target=0 }
  END { exit !found }
' "$work_dir/make.db"; then
  printf 'No build target; packaging the full source archive.\n'
  gzip -c "$work_dir/source.tar" > "$work_dir/artifact.tar.gz"
  exit 0
fi

read_output_dir
printf 'Building %s on the Git server (output: %s).\n' "$PUSH_DEPLOY_REVISION" "$output_dir"
make build
[[ -d $output_dir ]] || die "Build did not produce output directory: $output_dir"
[[ $(realpath -e -- "$output_dir") == "$PWD/$output_dir" ]] || die 'output_dir must not resolve through symlinks.'
[[ -f $makefile && ! -L $makefile ]] || die 'Build removed or replaced the Makefile with a symlink.'
tar -czf "$work_dir/artifact.tar.gz" -- "$makefile" "$output_dir"
