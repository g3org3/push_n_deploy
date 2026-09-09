# Push and deploy

Bash scripts for a small, trusted-team Git deployment server:

```text
developer / CI --git push--> Git server --SSH + tar.gz--> target
                             optional make build         make deploy
```

Each project has a bare repository, one deployment branch (default `main`),
and one target. The Git server extracts the pushed revision into a temporary
directory. If the Makefile defines `build`, it runs `make build` and packages
the output directory plus the Makefile and `mise.toml` when present. Otherwise it packages the full Git
source archive. The target extracts the `.tar.gz` into a fresh release directory,
runs `make deploy` there, and updates a `current` symlink only when the command
succeeds. An optional systemd user service is restarted after the symlink switch.
The target does not need to clone the repo.

When the release contains `mise.toml`, deployment ensures mise is available on
the target, trusts that config, installs its tools as the deployment SSH user,
and runs `make deploy` through `mise exec`. Runtime installation failures stop
deployment before switching `current` or restarting the service.

## 1. Prepare the Git server

Copy this project to the Git server. The dependency installer supports
Debian/Ubuntu; account management assumes Linux with `useradd` and `runuser`.
Run administrative scripts as root:

```bash
sudo bash scripts/install-dependencies.sh git-server
sudo bash scripts/setup-git-user.sh
sudo bash scripts/create-repo.sh george myapp
sudo bash scripts/add-push-key.sh /path/to/developer-or-ci.pub
```

Both dependency installation roles install `curl`, CA certificates, and
[mise using its official installer](https://mise.jdx.dev/installing-mise.html#https-mise-run).
The mise binary is installed at `/usr/local/bin/mise` so the deployment account
can use it too. An existing executable at that path is reused. Project tools
and shell activation can be configured separately. Deployments containing
`mise.toml` automatically install its tools on the target without shell activation.

The account is `git`, its home is `/srv/git`, and repositories live at
`/srv/git/OWNER/REPO` without a `.git` suffix. Creation takes `OWNER NAME`;
the owner is a namespace, not a separate Linux account or access restriction.
Owners can each have a repository with the same name. Owner and repository
names use letters, digits, underscores, and hyphens; `git-shell-commands` is
reserved as an owner name. SSH resolves the relative `OWNER/REPO` path from
the Git account's home. For a different account, supply `sudo env GIT_USER=...`
consistently to each account/repository script. An existing account must already
use `git-shell` and the expected home; the script refuses to convert ordinary users.

After creating a repo, the script prints copyable commands for creating a new
local repository or pushing an existing one, using `origin` and `main`.
The remote always uses the server's hostname (`hostname -f`, falling back to
`hostname`).

`git-shell` is Git's restricted login shell, distinct from the Windows Git Bash
terminal. Push keys get `restrict` options to disable forwarding, PTYs, and SSH
user startup scripts. The account password is locked. Ensure your SSH service
allows public-key authentication for this account and is running/reachable;
these scripts do not rewrite global SSH policy or firewall rules.

All authorized push keys can read and write all repositories on this account.
Add a new machine by copying **its public key**, never its private key, to the
Git server and running `add-push-key.sh`. To revoke access, remove its line from
`/srv/git/.ssh/authorized_keys` as root.

## 2. Prepare the deployment target

On the target, install runtime prerequisites:

```bash
sudo bash scripts/install-dependencies.sh target
```

Use a dedicated ordinary SSH account such as `deploy`, with a working Bash
shell and write access to a dedicated application directory such as
`/srv/apps/myapp`. Create that account/directory using your server's normal
administration process. Install the application's own dependencies separately.

Generate a **separate outbound deployment key** on the Git server:

```bash
sudo ssh-keygen -t ed25519 -N '' -f /root/myapp-deploy -C myapp-deployment
```

On the target, add the contents of `/root/myapp-deploy.pub` to the deploy user's
`~/.ssh/authorized_keys`, prefixed with `restrict ` on the same line. Set `.ssh`
to mode `700` and `authorized_keys` to `600`, both owned by that user.
The target account must allow remote commands; do not give it `git-shell`.

Collect the target's host key on the Git server:

```bash
ssh-keyscan -H target.example.com > /tmp/myapp-known-hosts
ssh-keygen -lf /tmp/myapp-known-hosts
```

Compare the fingerprints through a trusted channel, such as the target's
console (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`). `ssh-keyscan`
alone does not authenticate the server. Only use the file after verification.
For a custom SSH port, use `ssh-keyscan -p PORT` and supply the same port below.

## 3. Wire up deployment

On the Git server:

```bash
sudo bash scripts/setup-deployment.sh \
  george myapp deploy@target.example.com /srv/apps/myapp \
  /root/myapp-deploy /tmp/myapp-known-hosts main 22
```

The last two arguments are optional. The target accepts a DNS name or IPv4
address. The script copies credentials and hook configuration into
`/srv/git/.push-n-deploy/george/myapp`, protected from other system users. It refuses
to overwrite an existing deployment or hook. To change settings, edit its
root-owned `config` file as Bash assignments; keep ownership and permissions.
When run interactively, setup also asks whether to install a systemd user service
on the target. Noninteractive setup skips that question; a service can be added later.

To upgrade an existing deployment to the current hook implementation, pause
pushes while updating, copy the current version of these scripts to the Git
server, and run:

```bash
sudo bash scripts/install-dependencies.sh git-server
sudo bash scripts/setup-git-user.sh
sudo bash scripts/update-deployment.sh george myapp
```

The update preserves the deployment configuration and SSH keys. Rerunning user
setup adds writable `.local`, `.cache`, `.config`, and `.npm` directories for build
tools. It also repairs ownership inside an existing `.npm` cache. If npm reports
`EACCES` for `/srv/git/.npm`, rerun `setup-git-user.sh` on the Git server and retry
deployment. Keep the Git account's home root-owned; only its tool directories
need to be writable. The script uses the account's actual UID/group rather than
the numeric IDs suggested in npm's error message.
Update target dependencies with `install-dependencies.sh target` on that machine.

Your project needs a Makefile with a `deploy` target. For example:

```makefile
.PHONY: deploy
deploy:
	./scripts/deploy.sh
```

Make recipes require a real tab. `make deploy` runs inside the new release
directory, with `PUSH_DEPLOY_REVISION` set to the commit ID. At that point,
`current` still points to the previous successful release. Make should deploy
from its working directory; if your service serves `current` directly, the
symlink switches after Make succeeds. Service restart/activation requirements
can be handled by the optional systemd user service below.

### Optional systemd user service

For an existing deployment, run this on the Git server:

```bash
sudo bash scripts/setup-user-service.sh george myapp
```

The script asks for:

- A service name, defaulting to `george.myapp.service`.
- A restart policy: `on-failure` (default), `always`, or `no`.
- Whether to enable lingering so the user service can run after logout and at
  boot (default yes). Answering no leaves existing lingering settings unchanged.

The service command is always `make run`, executed from `TARGET_DIR/current`.
When `mise.toml` is present, the runner uses `mise exec -- make run` so the recipe
can use the installed tools. Define a foreground `run` target in your Makefile,
for example:

```makefile
.PHONY: run
run:
	node build/server.js
```

Keep the process in the foreground; do not add `&` or start a separate daemon.
To replace an existing custom service command with `make run`, rerun
`setup-user-service.sh OWNER NAME` using its existing service name. The next
deployment or a manual user-service restart will use the updated runner.

It connects using the deployment's saved SSH identity and host verification.
The target must run systemd. Run `install-dependencies.sh target` there to install
systemd, `libpam-systemd`, and `dbus-user-session`, along with the other dependencies;
reconnect SSH after installing the user-session packages if necessary.

The installer tries to enable lingering as the SSH user, then with noninteractive
sudo. If neither is permitted, it stops with the administrator command to run on
the target, for example:

```bash
sudo loginctl enable-linger deploy
```

Rerun service setup after that command. Ordinary deployments use
`systemctl --user` and do not require sudo. See the
[systemd lingering documentation](https://www.freedesktop.org/software/systemd/man/252/loginctl.html).

The generated unit lives in the target user's `~/.config/systemd/user/`, and its
Bash command runner lives in `~/.local/share/push-n-deploy/SERVICE/`. The corresponding
XDG config/data overrides are respected. The working directory is always
`TARGET_DIR/current`. The runner adds `/usr/local/bin` and `~/.local/bin` to PATH;
use `mise exec` for mise-managed tools. Service setup ensures mise is installed:
it reuses an available executable or installs it with the official `mise.run`
installer at `~/.local/bin/mise` as the target user. Automatic installation needs
`curl` and CA certificates; the target dependency script installs both.
Artifact deployments include the project's `mise.toml` when present, and each
deployment installs its configured tools before running Make or restarting the service.

Setup validates the unit, reloads the user manager, and enables the service. It
starts/restarts on the next successful deployment, allowing service setup before
the first release exists. Rerunning setup updates the same managed service; it
refuses to overwrite an unrelated unit or rename a deployment's existing service.
The script also updates the local deployment hooks automatically.

After each successful `make deploy`, the hook switches `current`, restarts the
configured service, and checks that it is active. A Make failure does not switch
`current` or restart the service. If restart fails or the service is immediately
inactive, deployment reports failure and prints service status; `current` remains
on the new release. This is an immediate process-state check, not an application
readiness check or an automatic rollback.

Inspect the service as the SSH deployment user on the target:

```bash
systemctl --user status george.myapp.service
journalctl --user -u george.myapp.service -n 100 --no-pager
```

To stop managing it on push, remove
`/srv/git/.push-n-deploy/george/myapp/service` as root on the Git server. To stop
the service itself, run `systemctl --user disable --now george.myapp.service`
as the deployment user on the target.

### Optional build on the Git server

Define a `build` target to enable artifact deployment. The hook uses GNU Make's
parsed target database, so targets defined with variables or included Makefiles
are recognized. Target detection does not run recipes, although Make's parse-time
expressions such as `$(shell ...)` still execute. Invalid Makefiles stop deployment.
A build failure or missing output directory also stops deployment; neither falls
back to sending source.

The output directory defaults to `./dist`. Override it in a tracked
`.push_n_deploy.yml`:

```yaml
output_dir: ./build
```

The Bash parser supports only this top-level string setting, optionally quoted,
plus blank lines and comments. If the file or setting is absent, `./dist` is used.
An empty or malformed setting is an error. Paths must name a directory inside
the checkout; absolute paths, `..`, the checkout root, and paths through symlinks
are rejected. Config is read only when a build target exists.

For example, if `npm run build` produces `build/`:

```makefile
.PHONY: build deploy
build:
	npm ci
	npm run build

deploy:
	mkdir -p "$(HOME)/www/myapp"
	cp -a build/. "$(HOME)/www/myapp/"
```

This example copies static assets into the deployment user's web directory;
adapt `deploy` to your service. `build` runs as the Git account on the Git server,
and `deploy` runs as the target SSH account. Both receive `PUSH_DEPLOY_REVISION`.
When a build target and `mise.toml` are present, the Git server ensures mise is
available, runs `mise trust ./mise.toml` and `mise install`, then executes
`mise exec -- make build`. Recipes can use plain `npm`, `node`, `python`, etc.
Trust or installation failures stop deployment before any artifact is sent.
Without `mise.toml`, the hook runs plain `make build`. Source-only projects skip
build-side mise setup. Interactive shell activation is not required.
Commit `mise.toml`, your package
lockfile, and other build inputs. Build dependencies must support the Git server's
OS/architecture, and generated artifacts must be compatible with the target.

The artifact preserves the output directory name (`build/`, not just its contents)
and includes hidden output files. That directory, the selected Makefile
(`GNUmakefile`, `makefile`, or `Makefile`, in Make's precedence order), and
`mise.toml` when present are sent. The config must be a regular file, not a symlink.
Any deploy-time scripts, config, or included makefiles must therefore live in the
output directory, or the deploy recipe must be self-contained. In particular,
`deploy` should not depend on `build`: the target no longer has the source inputs.
Completed `.tar.gz` artifacts are saved on the Git server under
`/srv/git/.push_n_deploy/OWNER/REPO/` (or the configured Git account's home).
Filenames contain a UTC timestamp, commit ID, and unique suffix. The newest
three archives per repository are retained; each completed archive replaces
the oldest when the limit is exceeded. This includes full-source bundles for
projects without a build target and artifacts whose SSH transfer or target
deployment fails. Failed builds do not publish an archive or prune previous
ones. Temporary checkouts and staging files are still removed.

Artifact storage uses `.push_n_deploy` with underscores; SSH keys and hook
configuration remain in the existing `.push-n-deploy` directory. Run
`update-deployment.sh OWNER NAME` to enable retention on an existing deployment.

## 4. Push

From your development machine or CI:

```bash
git remote add deploy git@git.example.com:george/myapp
git push deploy main
```

Use an SSH config entry on the pushing machine if you need a particular key
or a nonstandard Git-server port. Output from `make build` and `make deploy` appears in the push
output. Pushes to other branches, tags, and branch deletions do not deploy.
New repositories reject non-fast-forward updates.

## GitHub webhook deployment (alternative)

Instead of pushing to this Git server, a Bun HTTP server can receive GitHub
`push` webhooks directly: it clones the repo, runs `make build` (mise-aware,
reading `output_dir` from `.push_n_deploy.yml`), and deploys the build output
to the target over SSH with the same release/`current` mechanics. State lives
in `/srv/git/.github_webhook` with one shared SSH deploy key for all repos.

See `github_webhook/README.md`. Summary:

```bash
sudo bash github_webhook/install-server.sh   # on the Git server; serves :9090
sudo bash github_webhook/register-repo.sh george myapp \
  --url https://github.com/george/myapp.git \
  --target deploy@target.example.com --dir /srv/apps/myapp
# then run the printed `gh api .../hooks` command to register the webhook
```

## Roll back a deployment

On the Git server:

```bash
sudo bash scripts/rollback.sh g3org3 test_repo
```

The script uses the repository's saved target, SSH credentials, and optional
service name. On the target it selects the previous available successful release,
prepares its mise tools if configured, runs `make deploy` inside that release,
switches `current`, and restarts/checks the configured systemd user service.
`PUSH_DEPLOY_REVISION` contains the selected release's commit ID. It reuses the
target's existing release directory; no rebuild or artifact upload is required.

Deployments record success in `TARGET_DIR/.push-n-deploy-history` only after Make
and the optional service check pass. Failed activations are excluded. If `current`
points to a failed deployment, rollback selects the latest recorded success.
Otherwise it selects the success before `current`. Missing or symlinked release
directories are skipped. Repeated successful rollbacks walk farther backward;
they do not toggle between two versions. Newer history entries are discarded
after rollback, but their release directories remain on disk.

For existing installations, update hooks first:

```bash
sudo bash scripts/update-deployment.sh g3org3 test_repo
```

History starts with deployments made using these updated hooks. Normal rollback
requires two recorded successful releases; recovering a failed new activation
requires one earlier recorded success. Older untracked directories cannot reliably
be distinguished from failed deployments, so the script does not guess from dates.

Push deployments and rollback use the same Git-server and target locks. A runtime
installation or Make failure leaves `current` unchanged. A service failure after
the switch returns an error and leaves `current` on the selected release; inspect
the user journal before retrying. Rollback does not change Git branches, undo
database migrations, or reverse other external effects of your Makefile. The next
push to the deployment branch deploys normally.

## Behavior and limits

- Git accepts a push before running `post-receive`. A deployment failure is
  reported prominently, but **cannot undo the push or make Git reliably report
  push failure**. CI should check deployment status separately if required.
- To retry the current branch tip without a new commit, run on the Git server:

  ```bash
  sudo runuser -u git -- bash -c '
    cd /srv/git/george/myapp
    revision=$(git rev-parse refs/heads/main)
    printf "%s %s refs/heads/main\n" "$revision" "$revision" | hooks/post-receive
  '
  ```

- Deployments serialize per repository and per target directory. Queued hooks
  skip revisions already superseded by a newer push. An already-running deployment
  completes before the next one starts. A hanging Make command blocks later
  deployments; application-specific timeouts belong in your deploy recipe.
- Successful and failed releases remain under `releases/` for inspection.
  There is no automatic cleanup or rollback of external effects from Make.
  Remove old releases according to your retention policy, preserving `current`.
- Without a build, release directories contain Git archive contents, including
  tracked dotfiles. With a build, they contain the generated output, Makefile,
  and optional `mise.toml`.
  Build inputs come from Git archives: no `.git` directory, untracked files,
  expanded Git LFS objects, or submodule contents. Git's `export-ignore` and
  `export-subst` attributes apply. Keep persistent data and secrets outside releases.
- Anyone who can push the deployment branch can run code as the Git account
  on the Git server and as the target's deploy user via the Makefile. Use this
  for trusted collaborators, restrict both accounts' privileges, and avoid sharing one target directory between
  unrelated repositories. This provides no per-repository key isolation.
- The deployment hook is synchronous; long deployments keep the push connection
  open. This is intentionally a small setup, without a queue, dashboard, or
  deployment health checks.

## Verification

```bash
for script in scripts/*.sh scripts/lib/*.sh tests/*.sh; do bash -n "$script" || exit; done
bash tests/integration.sh
bash tests/user-service.sh
bash tests/mise.sh
bash tests/rollback.sh
```

The integration test uses real Git pushes to an `OWNER/REPO` relative remote
through `git-shell`, replacing SSH with local execution. It checks the pushed revision, branch/tag filtering,
quoted paths, stale/deleted refs, Make/SSH failures, and preservation of the
last successful `current`. It also checks gzip artifacts, default/custom build
output, included build targets, source fallback, and invalid/missing output.
Retention checks cover the three-archive limit, failed builds/transfers, archive
integrity, and isolation between repositories.
Service tests use mocked SSH/systemd actions to check installation, lingering
failures, safe updates, `make run` with and without mise, restart ordering and failure reporting.
They also validate a generated unit with the real `systemd-analyze` when available.
Mise checks cover installer reuse/download failure, artifact config inclusion,
and runtime preparation before deployment. Installer and runtime commands are
mocked so tests do not download tools or change the local account.
Rollback tests cover successful-release selection, repeated rollback, Make/mise
and service failures, removed releases, missing history, and unsafe history entries.
Account creation, package installation, and real
SSH authentication and user-service startup still need a smoke test on your servers.

Design references: [Git hooks](https://git-scm.com/docs/githooks),
[git-shell](https://git-scm.com/docs/git-shell), and
[OpenSSH authorized keys](https://man.openbsd.org/sshd#AUTHORIZED_KEYS_FILE_FORMAT).
