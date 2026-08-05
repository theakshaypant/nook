#!/usr/bin/env bash
set -euo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/nook"
CACHE_FILE="$CACHE_DIR/github_data.json"
CACHE_MAX_AGE=840

mkdir -p "$CACHE_DIR"

if [[ -f "$CACHE_FILE" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE") ))
    if (( age < CACHE_MAX_AGE )); then
        cat "$CACHE_FILE"
        exit 0
    fi
fi

notif_json=$(gh api /notifications --paginate --jq '[.[] | {
    title: .subject.title,
    repo: .repository.full_name,
    type: .subject.type,
    reason: .reason,
    unread: .unread,
    updated: .updated_at,
    url: .subject.url
}]' 2>/dev/null) || notif_json="[]"

jq -n \
    --argjson notifs "$notif_json" \
    --arg now "$(date '+%H:%M')" \
    '($notifs | reduce .[] as $n (
        {total: 0, unread: 0, mention: 0, review_requested: 0, assign: 0, ci_activity: 0, comment: 0};
        .total += 1
        | (if $n.unread then .unread += 1 else . end)
        | if   $n.reason == "mention"          then .mention += 1
          elif $n.reason == "review_requested" then .review_requested += 1
          elif $n.reason == "assign"           then .assign += 1
          elif $n.reason == "ci_activity"      then .ci_activity += 1
          elif ($n.reason == "comment" or $n.reason == "subscribed") then .comment += 1
          else . end
    )) as $counts |
    {
        total: $counts.total,
        unread: $counts.unread,
        by_reason: {
            mention:          $counts.mention,
            review_requested: $counts.review_requested,
            assign:           $counts.assign,
            ci_activity:      $counts.ci_activity,
            comment:          $counts.comment
        },
        items: [($notifs | sort_by(.updated) | reverse)[] |
            (.url | split("/") | last) as $num |
        {
            title: .title,
            repo: (.repo + (if (.type == "PullRequest" or .type == "Issue" or .type == "Discussion") and $num != null
                             then "#" + $num else "" end)),
            type: (if .type == "PullRequest" then "PR"
                   elif .type == "Issue" then "Issue"
                   elif .type == "Discussion" then "Disc"
                   elif .type == "CheckSuite" then "CI"
                   elif .type == "Release" then "Rel"
                   else .type end),
            url: (if .url then
                    (.url | gsub("api\\.github\\.com/repos"; "github.com")
                          | gsub("/pulls/"; "/pull/")
                          | gsub("/commits/"; "/commit/"))
                  else ("https://github.com/" + .repo) end)
        }],
        updated: $now
    }' | tee "$CACHE_FILE"
