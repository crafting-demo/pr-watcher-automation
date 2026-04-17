# pr-watcher sandbox template

A Crafting sandbox template for user-owned automations of the shape
"do something every time a pull request is opened on `${org}/${repo}`".

## What it does

A single long-running workspace runs a job on `*/5 * * * *`. Every poll:

1. Mints a short-lived GitHub App installation token for
   `${TARGET_GITHUB_ORG}/${TARGET_GITHUB_REPO}` via Crafting's workspace
   credential helper.
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
- `scripts/watch-prs.sh` — cron body. Uses the workspace
  `wsenv git-credentials` helper to mint a short-lived GitHub App
  installation token, then runs `gh pr list` + `--template`; no
  `curl`/`jq` dependency.
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

## GitHub App Requirement

This template does **not** require a user PAT or a private secret. Instead,
`scripts/watch-prs.sh` asks Crafting's workspace credential helper for a
short-lived GitHub App installation token for the target repo, then exports it
as `GH_TOKEN` / `GITHUB_TOKEN` for `gh`.

Before launching the sandbox, make sure the current Crafting org has the
GitHub App connected in the Web Console:

```text
Connect → GitHub
```

The installation must:

- include the target repo
- have at least repository permission `Pull requests: Read`

### Identity model

This automation runs using the org-shared GitHub App identity, not the
individual user's personal GitHub identity. That means no user PAT is needed,
but access is controlled by the app installation's repository selection and
permissions.

### If you extend the handler

If `scripts/on-new-pr.sh` needs to do more than list PRs, update the GitHub
App installation permissions accordingly:

| Extra action the handler performs       | GitHub App repository permission |
| --------------------------------------- | -------------------------------- |
| Comment on the PR / update PR body      | Pull requests: Read and write    |
| Create/update commit statuses or checks | Commit statuses: Read and write, or Checks: Read and write |
| Read repo contents via API or clone     | Contents: Read                   |
| `workflow_dispatch` a GitHub Actions run| Actions: Read and write          |

## How to launch it

```sh
# 1. Point the template at your repo (edit sandbox.yaml or override at create time).
#    No PAT or private secret is needed; auth comes from the connected GitHub App.
cs sandbox create pr-watcher-my-repo \
    --from def:sandbox.yaml \
    -E TARGET_GITHUB_ORG=my-org \
    -E TARGET_GITHUB_REPO=my-repo

# 2. Watch logs.
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

`watch-prs.sh` exports `GH_TOKEN` and `GITHUB_TOKEN` as the short-lived GitHub
App installation token for the watched repo, so follow-on GitHub API calls can
reuse it if the app installation has the required permissions.
