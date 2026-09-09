# GitHub webhook deploy server

A Bun HTTP server that receives GitHub `push` events and deploys the `main`
branch without any git push to this server: it clones the repo, runs
`make build` (through `mise exec` when the repo has `mise.toml`), and ships
the build output over SSH to the target, where `make deploy` runs inside a
fresh release directory and `current` switches only on success (mirroring
push_n_deploy). An optional systemd user service is restarted after the
switch.

```text
GitHub push --webhook--> Bun server (git server) --SSH + tar.gz--> target
                          clone + make build       make deploy
```

State lives in `/srv/git/.github_webhook`, next to push_n_deploy's
`/srv/git/.push_n_deploy`:

```text
/srv/git/.github_webhook/
  bin/server.ts        webhook server (installed by install-server.sh)
  bin/deploy.sh        per-push worker: clone, build, ship, activate
  identity             one shared deploy key for ALL repos (set up once)
  identity.pub         its public key, to install on each target
  known_hosts          verified target host keys (append as targets are added)
  OWNER/REPO/config    repo_url, branch, target, destination, port, service
  OWNER/REPO/secret    webhook secret (GitHub signs payloads with it)
  OWNER/REPO/logs/     one log per push
  OWNER/REPO/state/    last deployed revision (skips stale pushes)
```

## 1. Install the server (git server, as root)

```bash
sudo bash github_webhook/install-server.sh
```

Installs Bun if missing, copies `bin/`, and enables `github-webhook.service`
(listening on `PORT` 9090 by default as the `git` account). Open the port to
GitHub (`sudo ufw allow 9090/tcp`) or reverse-proxy `127.0.0.1:9090`.

## 2. Register a repository (git server, as root)

```bash
sudo bash github_webhook/register-repo.sh george myapp \
  --url https://github.com/george/myapp.git \
  --target deploy@target.example.com \
  --dir /srv/apps/myapp \
  [--branch main] [--port 22] [--service myapp.service] \
  [--secret HEX32] [--force]
```

This writes the per-repo config and generates the webhook secret. On first
run it also generates the shared deploy key and prints the line to add to the
target's `~/.ssh/authorized_keys` (prefixed with `restrict`); verify the
target host key with `ssh-keyscan -H ... > /srv/git/.github_webhook/known_hosts`
before first registration. Cloning assumes access is already provisioned
(public repo or credentials on the git server); no token is stored.

The script prints the exact `gh` command to create the webhook on GitHub —
run it where `gh` is authenticated against that repo:

```bash
gh api repos/george/myapp/hooks -X POST \
  -f url="http://GITSERVER:9090/george/myapp" \
  -f content_type=json -f secret=<hex> -f 'events[]=push' -F active=true
```

## Flow details

- Only `push` events on the configured branch (default `main`) deploy;
  `ping` answers `pong`; other events and refs are ignored.
- Payloads are verified with HMAC-SHA256 against the per-repo secret
  (timing-safe comparison); duplicate delivery ids are dropped.
- The HTTP request returns `202 queued` immediately; the build runs in the
  background with output in `OWNER/REPO/logs/`.
- A per-repo lock serializes deployments; only the latest revision deploys,
  and an already-deployed revision is skipped.
- The remote keeps the newest three releases under `DEST/releases/` and
  repoints `current` only after a successful `make deploy`.

The build reads `output_dir` from `.push_n_deploy.yml` (same convention as
push_n_deploy, default `dist`) and ships that directory plus the Makefile and
`mise.toml` to the target.
