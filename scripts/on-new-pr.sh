#!/usr/bin/env bash
# Placeholder per-PR handler. The watcher cron calls this once for every PR
# number it has not seen before. Replace the body with whatever the user /
# Crafting Assistant wants to happen for each new PR (e.g. `cs sandbox create`
# to stand up a fresh sandbox on the PR branch, kick off a test job, send a
# Slack notification, etc.).
#
# Exit 0 => PR is marked as seen and will not be revisited.
# Exit != 0 => PR is NOT marked and will be retried on the next poll.

set -euo pipefail

pr_number="$1"
pr_branch="$2"
pr_html_url="$3"
pr_title="$4"

echo "[$(date -Is)] [placeholder] on-new-pr triggered"
echo "    number: ${pr_number}"
echo "    branch: ${pr_branch}"
echo "    url:    ${pr_html_url}"
echo "    title:  ${pr_title}"

exit 0
