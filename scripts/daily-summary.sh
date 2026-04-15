#!/usr/bin/env bash
#
# daily-summary.sh — Generate a daily commit summary for the BSE GitHub org.
#
# Usage:
#   ./scripts/daily-summary.sh              # today's commits
#   ./scripts/daily-summary.sh 2026-04-14   # specific date
#   ./scripts/daily-summary.sh week         # last 7 days
#
# Requirements: gh (GitHub CLI), authenticated with `gh auth login`

set -euo pipefail

ORG="Business-Systems-Engineering"

# ---------------------------------------------------------------------------
# Resolve the date range
# ---------------------------------------------------------------------------
case "${1:-today}" in
  today)
    SINCE=$(date +%Y-%m-%d)
    LABEL="today ($SINCE)"
    QUERY="author-date:${SINCE}"
    ;;
  week)
    if [[ "$OSTYPE" == darwin* ]]; then
      SINCE=$(date -v-7d +%Y-%m-%d)
    else
      SINCE=$(date -d '7 days ago' +%Y-%m-%d)
    fi
    LABEL="last 7 days (since $SINCE)"
    QUERY="author-date:>=${SINCE}"
    ;;
  *)
    SINCE="$1"
    LABEL="$SINCE"
    QUERY="author-date:${SINCE}"
    ;;
esac

echo "=========================================="
echo " BSE Daily Commit Summary"
echo " Scope : $ORG"
echo " Period : $LABEL"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# Fetch commits from GitHub Search API (covers all org repos in one call)
# ---------------------------------------------------------------------------
RAW=$(gh api search/commits \
  -X GET \
  -f "q=org:${ORG} ${QUERY}" \
  -f "sort=author-date" \
  -f "order=desc" \
  -f "per_page=100" \
  --jq '.items[] | {
    repo:    .repository.full_name,
    sha:     .sha[:7],
    message: (.commit.message | split("\n")[0]),
    author:  .commit.author.name,
    date:    .commit.author.date,
    url:     .html_url
  }' 2>&1)

if [[ -z "$RAW" ]]; then
  echo "No commits found for $LABEL."
  exit 0
fi

# ---------------------------------------------------------------------------
# Group by repo, then print each group sorted by time descending
# ---------------------------------------------------------------------------
GROUPED=$(echo "$RAW" | jq -s 'group_by(.repo) | map({
  repo: .[0].repo,
  commits: (sort_by(.date) | reverse)
}) | sort_by(.repo)')

TOTAL=$(echo "$GROUPED" | jq '[.[].commits | length] | add')
REPO_COUNT=$(echo "$GROUPED" | jq 'length')

echo "$GROUPED" | jq -c '.[]' | while IFS= read -r group; do
  repo=$(echo "$group" | jq -r '.repo')
  echo "## $repo"
  echo "------------------------------------------"

  echo "$group" | jq -c '.commits[]' | while IFS= read -r commit; do
    time_part=$(echo "$commit" | jq -r '.date' | sed 's/.*T\([0-9:]*\).*/\1/' | cut -c1-5)
    author=$(echo "$commit" | jq -r '.author')
    sha=$(echo "$commit" | jq -r '.sha')
    message=$(echo "$commit" | jq -r '.message')
    printf "  %s  %-10s  %s  %s\n" "$time_part" "$author" "$sha" "$message"
  done

  echo ""
done

echo "=========================================="
echo " Total: $TOTAL commit(s) across $REPO_COUNT repo(s)"
echo "=========================================="
