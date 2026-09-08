# Push and deploy

Bash scripts for a small, trusted-team Git deployment server:

```text
developer / CI --git push--> Git server --SSH + source archive--> target
                             git-shell                         make deploy
```

Each project has a bare repository, one deployment branch (default `main`),
and one target. The target receives the exact pushed Git archive in a fresh
release directory, runs `make deploy` there, and updates a `current` symlink
only when the command succeeds. The target does not need to clone the repo.

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
and shell activation are configured separately; your Makefile can invoke mise
explicitly without interactive shell activation.

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
belong in your application's deployment design.

## 4. Push

From your development machine or CI:

```bash
git remote add deploy git@git.example.com:george/myapp
git push deploy main
```

Use an SSH config entry on the pushing machine if you need a particular key
or a nonstandard Git-server port. Output from `make deploy` appears in the push
output. Pushes to other branches, tags, and branch deletions do not deploy.
New repositories reject non-fast-forward updates.

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
- Release directories contain Git archive contents, including tracked dotfiles.
  They have no `.git` directory, untracked files, expanded Git LFS objects, or
  submodule contents. Git's `export-ignore` and `export-subst` attributes apply.
  Keep persistent data and secrets outside release directories.
- Anyone who can push the deployment branch can run code as the target's
  deploy user via the Makefile. Use this for trusted collaborators, restrict
  the deploy user's privileges, and avoid sharing one target directory between
  unrelated repositories. This provides no per-repository key isolation.
- The deployment hook is synchronous; long deployments keep the push connection
  open. This is intentionally a small setup, without a queue, dashboard, or
  deployment health checks.

## Verification

```bash
for script in scripts/*.sh scripts/lib/*.sh tests/*.sh; do bash -n "$script" || exit; done
bash tests/integration.sh
```

The integration test uses real Git pushes to an `OWNER/REPO` relative remote
through `git-shell`, replacing SSH with local execution. It checks the pushed revision, branch/tag filtering,
quoted paths, stale/deleted refs, Make/SSH failures, and preservation of the
last successful `current`. Account creation, package installation, and real
SSH authentication still need a smoke test on your servers.

Design references: [Git hooks](https://git-scm.com/docs/githooks),
[git-shell](https://git-scm.com/docs/git-shell), and
[OpenSSH authorized keys](https://man.openbsd.org/sshd#AUTHORIZED_KEYS_FILE_FORMAT).
