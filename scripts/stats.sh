#!/bin/bash
# Dhwani growth dashboard — all server-side, zero app telemetry.
# Requires: gh (authenticated as the repo owner for traffic data).
set -euo pipefail
REPO="gsp9145/dhwani"

echo "═══ Dhwani stats · $(date '+%Y-%m-%d %H:%M') ═══"
echo ""
echo "── Downloads (per release asset) ──"
gh api "repos/$REPO/releases" --jq '.[] | "\(.tag_name): \([.assets[].download_count] | add // 0) downloads"'
echo ""
echo "── Repo ──"
gh api "repos/$REPO" --jq '"stars: \(.stargazers_count)   forks: \(.forks_count)   watchers: \(.subscribers_count)   open issues: \(.open_issues_count)"'
echo ""
echo "── Repo traffic, last 14 days (owner-only) ──"
gh api "repos/$REPO/traffic/views" --jq '"views: \(.count) (\(.uniques) unique)"' 2>/dev/null || echo "views: n/a"
gh api "repos/$REPO/traffic/clones" --jq '"clones: \(.count) (\(.uniques) unique)"' 2>/dev/null || echo "clones: n/a"
echo ""
echo "── Where visitors come from ──"
gh api "repos/$REPO/traffic/popular/referrers" --jq '.[] | "  \(.referrer): \(.count) views (\(.uniques) unique)"' 2>/dev/null || echo "  none yet"
