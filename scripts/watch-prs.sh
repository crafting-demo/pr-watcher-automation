#!/usr/bin/env bash
# Cron body for the PR-watcher automation template.
#
# Runs every 5 minutes inside the pr-watcher sandbox. Reads the target repo
# from ${PR_WATCHER_TARGET_FILE}, mints a short-lived GitHub App installation
# token for that repo, lists the open PRs on it, diffs them against the
# plain-text state file, and calls on-new-pr.sh for every PR number seen for
# the first time.

set -euo pipefail

: "${PR_WATCHER_HOME:=${HOME}/pr-watcher}"
: "${PR_WATCHER_STATE_FILE:=${PR_WATCHER_HOME}/state/seen-prs.txt}"
: "${PR_WATCHER_TARGET_FILE:=${PR_WATCHER_HOME}/watch-target.txt}"

load_target_repo() {
  local raw=""
  local path

  if [[ ! -r "${PR_WATCHER_TARGET_FILE}" ]]; then
    echo "[$(date -Is)] ERROR: target repo file not found: ${PR_WATCHER_TARGET_FILE}" >&2
    return 1
  fi

  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    if [[ -z "${raw}" || "${raw:0:1}" == "#" ]]; then
      continue
    fi
    break
  done < "${PR_WATCHER_TARGET_FILE}"

  if [[ -z "${raw}" ]]; then
    echo "[$(date -Is)] ERROR: ${PR_WATCHER_TARGET_FILE} has no repo configured." >&2
    return 1
  fi

  case "${raw}" in
    https://github.com/*)
      path="${raw#https://github.com/}"
      ;;
    *)
      path="${raw}"
      ;;
  esac

  path="${path%.git}"
  path="${path%/}"
  TARGET_GITHUB_ORG="${path%%/*}"
  TARGET_GITHUB_REPO="${path#*/}"

  if [[ -z "${TARGET_GITHUB_ORG}" || -z "${TARGET_GITHUB_REPO}" || "${TARGET_GITHUB_REPO}" == */* ]]; then
    echo "[$(date -Is)] ERROR: ${PR_WATCHER_TARGET_FILE} must contain owner/repo or https://github.com/owner/repo on its first non-comment line." >&2
    echo "    Got: ${raw}" >&2
    return 1
  fi

  if [[ "${TARGET_GITHUB_ORG}" == "REPLACE_ME" || "${TARGET_GITHUB_REPO}" == "REPLACE_ME" ]]; then
    echo "[$(date -Is)] ERROR: ${PR_WATCHER_TARGET_FILE} still contains the REPLACE_ME placeholder." >&2
    return 1
  fi
}

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

load_target_repo
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
