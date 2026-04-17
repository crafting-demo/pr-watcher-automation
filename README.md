# pr-watcher sandbox template

A Crafting sandbox template for user-owned automations of the shape
"do something every time a pull request is opened on `${org}/${repo}`".

## What it does

A single long-running workspace runs a job on `*/5 * * * *`. Every poll:

1. Reads the sandbox owner's personal GitHub token from a user-private
   secret (`github-token`).
2. Calls `GET /repos/${TARGET_GITHUB_ORG}/${TARGET_GITHUB_REPO}/pulls?state=open`.
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
sandbox-creation time (via `cs sandbox create --env ...` or by rewriting the
YAML):

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
cs secret create -u github-token -f -
```

The secret is mounted at `/run/sandbox/fs/secrets/owner/github-token` and is
also interpolated into `$GITHUB_TOKEN` via the top-level `env` field
(`GITHUB_TOKEN=${secret:github-token}`). The watcher script uses the env var
first and falls back to reading the mount file, so either path works.

### Per-user GitHub login (LoginProvider) compatibility

Crafting recently added the `LoginProvider` feature — an org admin can set up
a `github` OAuth2 login provider (`cs org login-provider create github --template github ...`)
and each user can run `cs login -p github` once to authorise Crafting to
receive their personal GitHub access token. The token is persisted as a
per-user `Secret` of type `TOKEN` (see
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
cs secret create -u github-token -f -

# 2. Point the template at your repo (edit sandbox.yaml or override at create time).
cs sandbox create \
    --from sandbox.yaml \
    --env TARGET_GITHUB_ORG=my-org \
    --env TARGET_GITHUB_REPO=my-repo \
    --name pr-watcher-my-repo

# 3. Watch logs.
cs logs -f pr-watcher   # live stream
#   or
cat ~/pr-watcher/logs/watch-prs.log
```

To run the watcher once on demand (e.g. to validate the setup), either
`cs exec` into the workspace:

```sh
cs exec -W pr-watcher-my-repo/pr-watcher -- /home/owner/pr-watcher/watch-prs.sh
```

or `cs ssh` in and run the script by hand:

```sh
cs ssh pr-watcher-my-repo/pr-watcher
# inside the workspace:
~/pr-watcher/watch-prs.sh
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

- `cs sandbox create --from my-pr-sandbox.yaml --env PR_BRANCH="$2" ...`
  to stand up a dedicated sandbox per PR.
- Post to Slack via `curl` + an `OPAQUE` secret holding a bot token.
- Trigger a GitHub Actions workflow dispatch via
  `curl -X POST -H "Authorization: Bearer $GITHUB_TOKEN" ...`.
