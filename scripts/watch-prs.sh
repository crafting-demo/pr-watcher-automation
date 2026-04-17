#!/usr/bin/env bash
# Cron body for the PR-watcher automation template.
#
# Runs every 5 minutes inside the pr-watcher sandbox. Lists the open PRs on
# ${TARGET_GITHUB_ORG}/${TARGET_GITHUB_REPO} using the owner's GitHub token,
# diffs them against the plain-text state file, and calls on-new-pr.sh for
# every PR number seen for the first time.

set -euo pipefail

: "${TARGET_GITHUB_ORG:?TARGET_GITHUB_ORG must be set}"
: "${TARGET_GITHUB_REPO:?TARGET_GITHUB_REPO must be set}"
: "${PR_WATCHER_HOME:=/home/owner/pr-watcher}"
: "${PR_WATCHER_STATE_FILE:=${PR_WATCHER_HOME}/state/seen-prs.txt}"

# Prefer the env-expanded ${secret:github-token}. Fall back to the filesystem
# mount so the template still works if the operator runs the script by hand
# from a different workload that didn't inherit the sandbox env.
if [[ -z "${GITHUB_TOKEN:-}" && -r /run/sandbox/fs/secrets/owner/github-token ]]; then
  GITHUB_TOKEN="$(cat /run/sandbox/fs/secrets/owner/github-token)"
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "[$(date -Is)] ERROR: GITHUB_TOKEN is empty. Create the secret with:" >&2
  echo "    cs secret create github-token -f -" >&2
  exit 1
fi

# gh reads GH_TOKEN preferentially, then falls back to GITHUB_TOKEN. Export
# both so whichever build of gh we get behaves the same way.
export GH_TOKEN="${GITHUB_TOKEN}"
export GITHUB_TOKEN

mkdir -p "$(dirname "${PR_WATCHER_STATE_FILE}")"
touch "${PR_WATCHER_STATE_FILE}"

repo="${TARGET_GITHUB_ORG}/${TARGET_GITHUB_REPO}"

echo "[$(date -Is)] Polling ${repo}"

# One tab-separated row per open PR: number, head branch, url, title.
# --template runs Go text/template over the --json output, giving us stable
# TSV without shelling out to a separate jq.
prs_tsv="$(gh pr list \
  --repo "${repo}" \
  --state open \
  --limit 200 \
  --json number,headRefName,url,title \
  --template '{{range .}}{{.number}}{{"\t"}}{{.headRefName}}{{"\t"}}{{.url}}{{"\t"}}{{replace .title "\t" " "}}{{"\n"}}{{end}}')"

if [[ -z "${prs_tsv}" ]]; then
  echo "[$(date -Is)] No open PRs."
  exit 0
fi

current_numbers="$(printf '%s\n' "${prs_tsv}" | awk -F'\t' '{print $1}' | sort -u)"
seen_numbers="$(sort -u "${PR_WATCHER_STATE_FILE}" || true)"
new_numbers="$(comm -23 <(printf '%s\n' "${current_numbers}") <(printf '%s\n' "${seen_numbers}"))"

if [[ -z "${new_numbers}" ]]; then
  echo "[$(date -Is)] No new PRs since last poll."
  exit 0
fi

while IFS=$'\t' read -r number branch html_url title; do
  if ! printf '%s\n' "${new_numbers}" | grep -qx "${number}"; then
    continue
  fi
  echo "[$(date -Is)] NEW PR #${number} (${branch}): ${title} -- ${html_url}"
  if "${PR_WATCHER_HOME}/on-new-pr.sh" "${number}" "${branch}" "${html_url}" "${title}"; then
    echo "${number}" >> "${PR_WATCHER_STATE_FILE}"
  else
    echo "[$(date -Is)] on-new-pr.sh failed for PR #${number}; leaving it unmarked so it is retried next poll." >&2
  fi
done <<< "${prs_tsv}"
