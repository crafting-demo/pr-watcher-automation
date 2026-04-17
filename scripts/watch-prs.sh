#!/usr/bin/env bash
# Cron body for the PR-watcher automation template.
#
# Runs every 5 minutes inside the pr-watcher sandbox. Mints a short-lived
# GitHub App installation token for ${TARGET_GITHUB_ORG}/${TARGET_GITHUB_REPO},
# lists the open PRs on that repo, diffs them against the plain-text state
# file, and calls on-new-pr.sh for every PR number seen for the first time.

set -euo pipefail

: "${TARGET_GITHUB_ORG:?TARGET_GITHUB_ORG must be set}"
: "${TARGET_GITHUB_REPO:?TARGET_GITHUB_REPO must be set}"
: "${PR_WATCHER_HOME:=/home/owner/pr-watcher}"
: "${PR_WATCHER_STATE_FILE:=${PR_WATCHER_HOME}/state/seen-prs.txt}"

mint_github_app_token() {
  local repo="$1"
  local helper="/opt/sandboxd/sbin/wsenv"
  local request
  local credential
  local token

  request="$(printf 'protocol=https\nhost=github.com\npath=%s\n\n' "${repo}")"
  if ! credential="$("${helper}" git-credentials <<<"${request}")"; then
    echo "[$(date -Is)] ERROR: failed to get a GitHub App installation token for ${repo}." >&2
    echo "    Make sure the current Crafting org has Connect -> GitHub configured" >&2
    echo "    for ${TARGET_GITHUB_ORG}, and that the installation includes ${repo}" >&2
    echo "    with at least Pull requests: Read permission." >&2
    return 1
  fi

  token="$(sed -n 's/^password=//p' <<<"${credential}")"
  if [[ -z "${token}" ]]; then
    echo "[$(date -Is)] ERROR: git-credentials returned no password for ${repo}." >&2
    printf '%s\n' "${credential}" >&2
    return 1
  fi

  printf '%s\n' "${token}"
}

repo="${TARGET_GITHUB_ORG}/${TARGET_GITHUB_REPO}"
GITHUB_TOKEN="$(mint_github_app_token "${repo}")"

# gh reads GH_TOKEN preferentially, then falls back to GITHUB_TOKEN. Export
# both so whichever build of gh we get behaves the same way.
export GH_TOKEN="${GITHUB_TOKEN}"
export GITHUB_TOKEN

mkdir -p "$(dirname "${PR_WATCHER_STATE_FILE}")"
touch "${PR_WATCHER_STATE_FILE}"

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
