#!/usr/bin/env bash
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v bun >/dev/null || fail 'bun is required for this test.'
command -v curl >/dev/null || fail 'curl is required for this test.'

bash -n "$project/github_webhook/deploy.sh" || fail 'deploy.sh has syntax errors.'
bash -n "$project/github_webhook/register-repo.sh" || fail 'register-repo.sh has syntax errors.'
bash -n "$project/github_webhook/install-server.sh" || fail 'install-server.sh has syntax errors.'
bun build "$project/github_webhook/server.ts" --target=bun --outfile="$tmp/check.js" >/dev/null || fail 'server.ts does not compile.'

root="$tmp/github_webhook"
owner=george repo=myapp
mkdir -p "$root/$owner/$repo/logs" "$root/bin"
cp "$project/github_webhook/server.ts" "$root/bin/"
printf 'branch=main\n' > "$root/$owner/$repo/config"
secret=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
printf '%s\n' "$secret" > "$root/$owner/$repo/secret"
cat > "$root/bin/deploy.sh" <<EOF
#!/usr/bin/env bash
echo "\$3" >> "$root/calls.log"
EOF
chmod +x "$root/bin/deploy.sh"

port=$(( (RANDOM % 2000) + 5000 ))
PORT=$port GITHUB_WEBHOOK_ROOT=$root bun "$root/bin/server.ts" > "$tmp/server.out" 2>&1 &
server_pid=$!
trap 'rm -rf -- "$tmp"; kill -- "$server_pid" 2>/dev/null' EXIT
for _ in $(seq 50); do
  curl -s -o /dev/null "http://127.0.0.1:$port/healthz" && break
  sleep 0.1
done

post() { # event delivery body signature -> curl output
  curl -s -X POST -H "X-GitHub-Event: $1" -H "X-GitHub-Delivery: $2" \
    -H "X-Hub-Signature-256: $4" -d "$3" "http://127.0.0.1:$port/$owner/$repo"
}
sign() { printf 'sha256=%s' "$(printf '%s' "$1" | openssl dgst -sha256 -hmac "$secret" -r | cut -d' ' -f1)"; }
sha() { printf 'a%.0s' $(seq 1 40); }

[[ $(curl -s "http://127.0.0.1:$port/healthz") == ok ]] || fail 'healthz failed.'
[[ $(post ping d1 '{"zen":"ok"}' "$(sign '{"zen":"ok"}')") == pong ]] || fail 'ping failed.'
[[ $(post push d2 '{"ref":"refs/heads/main"}' sha256=0000) == 'invalid signature' ]] || fail 'bad signature accepted.'
[[ $(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' "http://127.0.0.1:$port/george/other") == 404 ]] || fail 'unregistered repo not 404.'
body='{"ref":"refs/heads/main","after":"'$(printf 'b%.0s' $(seq 1 40))'","repository":{"full_name":"george/myapp"}}'
[[ $(post push d3 "$body" "$(sign "$body")") == 'deploy of bbbbbbbb queued' ]] || fail 'push did not queue.'
[[ $(post push d4 '{"ref":"refs/heads/dev","after":"'$(sha)'","repository":{"full_name":"george/myapp"}}' "$(sign '{"ref":"refs/heads/dev","after":"'$(sha)'","repository":{"full_name":"george/myapp"}}')") == 'ref refs/heads/dev ignored (branch: main)' ]] || fail 'non-main ref not ignored.'
sleep 0.5
[[ $(< "$root/calls.log") == "$(printf 'b%.0s' $(seq 1 40))" ]] || fail 'deploy worker did not run with the revision.'
ls "$root/$owner/$repo/logs" | grep -q 'bbbbbbbb' || fail 'no log file written.'
printf 'github_webhook tests passed.\n'
