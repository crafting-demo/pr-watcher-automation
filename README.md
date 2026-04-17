# pr-watcher sandbox template

A Crafting sandbox template for user-owned automations of the shape
"do something every time a pull request is opened on `${org}/${repo}`".

## What it does

A single long-running workspace runs a job on `*/5 * * * *`. Every poll:

1. Reads the sandbox owner's personal GitHub token from a user-private
   secret (`github-token`).
2. Runs `gh pr list --repo ${TARGET_GITHUB_ORG}/${TARGET_GITHUB_REPO}
   --state open` and parses the result with `gh`'s `--template` flag.
3. Diffs the returned PR numbers against `~/pr-watcher/state/seen-prs.txt`.
4. For each new PR, runs `~/pr-watcher/on-new-pr.sh` and appends the PR
   number to the state file on success.

`scripts/on-new-pr.sh` is a placeholder that just prints what it would do.
The Crafting Assistant (or the user) is expected to replace its body with the
real per-PR action — e.g. `cs sandbox create` to spin up a per-PR sandbox, or
whatever the user asked for.

## Files

- `sandbox.yaml` — sandbox definition consumed by Crafting. Has one workspace
  with a Repo manifest that installs the scripts, installs the GitHub CLI
  (`gh`) from the official apt repo, and registers a cron-scheduled
  `jobs.watch-prs` entry.
- `scripts/watch-prs.sh` — cron body. Uses `gh pr list` + `--template` for
  PR enumeration; no `curl`/`jq` dependency.
- `scripts/on-new-pr.sh` — placeholder per-PR hook. Exits 0 by default.

## Parameters

The template's author / Crafting Assistant is expected to fill these in at
sandbox-creation time (via `cs sandbox create -E KEY=VALUE` — which appends
to the sandbox's env, so last-write-wins over the `REPLACE_ME` placeholders)
or by rewriting the YAML directly:

| Env var               | Meaning                                   |
| --------------------- | ----------------------------------------- |
| `TARGET_GITHUB_ORG`   | GitHub org/user that owns the target repo |
| `TARGET_GITHUB_REPO`  | GitHub repo name                          |

## Secret

The template references a **user-private OPAQUE** secret called
`github-token`. The owning user must create it once before launching the
sandbox:

```sh
# paste the PAT and press Ctrl-D
cs secret create github-token -f -
```

(`cs secret create` is user-private by default; pass `--shared` to make it
org-scoped instead. No `-u` flag on create.)

The secret is mounted at `/run/sandbox/fs/secrets/owner/github-token` and is
also interpolated into `$GITHUB_TOKEN` via the top-level `env` field
(`GITHUB_TOKEN=${secret:github-token}`). The watcher script uses the env var
first and falls back to reading the mount file, so either path works.

**Important:** user-private secrets are only surfaced to a sandbox when the
sandbox is created with private access (`--access=private`) or with explicit
sharing (`--access=collaborated:users=...:secrets=github-token`). In the
default (`shared`) access mode the FUSE mount omits private secrets and
`${secret:github-token}` expands to the empty string, so the watcher will
error out. See `system/pkg/sandbox/workload/agent2/ext/workspace/modules/secrets/filesystem.go:106-131`
and `system/pkg/sandbox/workload/agent2/modules/secrets.go:87-93`.

### What permissions does the PAT need?

The watcher only calls `gh pr list` on the target repo — a read-only operation
on pull requests — so the token can be scoped very narrowly. Pick the table
that matches the PAT type you're creating at
<https://github.com/settings/tokens>.

**Fine-grained PAT** (preferred — narrowest possible scope):

| Setting                 | Value                                             |
| ----------------------- | ------------------------------------------------- |
| Resource owner          | The org/user that owns `TARGET_GITHUB_REPO`       |
| Repository access       | *Only select repositories* → pick the target repo |
| Repository permissions  | **Pull requests: Read-only**                      |
|                         | *Metadata: Read-only* (auto-selected, mandatory)  |
| Organization perms      | none                                              |
| Account perms           | none                                              |

**Classic PAT** (coarser — GitHub doesn't offer a "PRs only" classic scope):

| Repo visibility | Minimum scope  | Notes                                            |
| --------------- | -------------- | ------------------------------------------------ |
| Public only     | `public_repo`  | Read/write on public repos only.                 |
| Any private     | `repo`         | Full read/write on all repos the user can reach. |

If you extend `scripts/on-new-pr.sh` to do more than read (e.g. post a PR
comment, create a check, dispatch a workflow, clone a private repo), bump the
token's scopes accordingly and update this section:

| Extra action the handler performs          | Fine-grained perm to add        | Classic scope to add          |
| ------------------------------------------ | ------------------------------- | ----------------------------- |
| Comment on the PR / update PR body         | Pull requests: Read and write   | covered by `repo`/`public_repo` |
| Create/update commit statuses or checks    | Commits: Read and write **or** Checks: Read and write | covered by `repo`/`public_repo` |
| `git clone` the PR branch                  | Contents: Read                  | covered by `repo`/`public_repo` |
| `workflow_dispatch` a GitHub Actions run   | Actions: Read and write         | `workflow`                    |

Set an expiry you're comfortable rotating (GitHub defaults fine-grained PATs
to 30 days) and store only the raw token value in the `github-token` secret —
no `ghp_` / `github_pat_` prefix stripping needed, `gh` handles both.

### Per-user GitHub login (LoginProvider) compatibility

Crafting recently added the `LoginProvider` feature — an org admin can set up
a `github` OAuth2 login provider
(`cs org login-provider create github --template github` + an OAuth client
config, see the public docs) and each user then runs `cs login --provider github`
once to authorise Crafting to receive their personal GitHub access token. The
token is persisted as a per-user `Secret` of type `TOKEN` (see
`docs/public/markdown/features/login-provider-and-access-tokens.md` and
`system/pkg/integration/login/`).

Today those `TOKEN`-type secrets are **not** surfaced to user code inside a
workspace — the FUSE secret mount
(`system/pkg/sandbox/workload/agent2/ext/workspace/modules/secrets/filesystem.go`)
and the `${secret:NAME}` env expansion
(`system/pkg/sandbox/workload/agent2/modules/secrets.go`) both filter to
`OPAQUE` / `SECRET` / `KEYPAIR` / `SSHKEY` only. The only consumer of the
`TOKEN` content is the LLM/MCP auth proxy
(`system/pkg/controller/llm.go`, `secretResolveToken`).

Until that plumbing is extended, this template points at an `OPAQUE` secret
the user maintains directly. If/when the system exposes the LoginProvider
token (e.g. at `/run/sandbox/fs/secrets/owner/login-token/github`), the fix
is a one-line change in `scripts/watch-prs.sh`: update the fallback path.

## How to launch it

```sh
# 1. One-time: create the user-private GitHub token secret.
cs secret create github-token -f -

# 2. Point the template at your repo (edit sandbox.yaml or override at create time).
#    NAME is positional; --access=private is required so the user-private
#    github-token secret is actually mounted.
cs sandbox create pr-watcher-my-repo \
    --from def:sandbox.yaml \
    --access=private \
    -E TARGET_GITHUB_ORG=my-org \
    -E TARGET_GITHUB_REPO=my-repo

# 3. Watch logs.
#    `cs logs` positional is a log-source name, not the sandbox — use -W to
#    point at the workspace. Omit the positional to get an interactive picker.
cs logs -f -W pr-watcher-my-repo/pr-watcher -k job watch-prs
#   or inside the workspace:
cat ~/pr-watcher/logs/watch-prs.log
```

To run the watcher once on demand (e.g. to validate the setup):

```sh
cs exec -W pr-watcher-my-repo/pr-watcher -- /home/owner/pr-watcher/watch-prs.sh
```

## State and idempotency

- `~/pr-watcher/state/seen-prs.txt` is a plain-text, newline-separated list of
  PR numbers already acted on. It survives sandbox suspend/resume because it
  lives in `home_snapshot`-backed storage by default.
- `scripts/watch-prs.sh` only marks a PR as seen **after** `on-new-pr.sh`
  exits 0. If the handler fails, the PR is retried on the next poll.

## Replacing the placeholder

When the Crafting Assistant (or the user) fills in the real action, edit
`scripts/on-new-pr.sh`. The script receives four args:

```
$1 = PR number    e.g. 1234
$2 = head branch  e.g. feat/my-change
$3 = html_url     e.g. https://github.com/org/repo/pull/1234
$4 = title        (tabs in the title are replaced with single spaces)
```

Common follow-on actions the assistant might drop in here:

- `cs sandbox create per-pr-$1 --from def:my-pr-sandbox.yaml -E PR_BRANCH="$2" ...`
  to stand up a dedicated sandbox per PR.
- Post to Slack via `curl` + an `OPAQUE` secret holding a bot token.
- Trigger a GitHub Actions workflow dispatch via
  `curl -X POST -H "Authorization: Bearer $GITHUB_TOKEN" ...`.
