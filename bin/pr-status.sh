#!/usr/bin/env bash
# 내가 올린 열린 PR의 현황을 3분류로 출력한다.
#   1) 리뷰 대기 — 승인 0건
#   2) 응답 필요 — 사람이 남긴 코멘트/미해결 스레드에 내 응답이 없음
#   3) 머지 대기 — 승인받았으나 아직 머지 안 함
#
# usage: pr-status.sh [--json]
set -euo pipefail

# 심볼릭 링크로 걸어 써도 lib 를 찾도록 실제 경로를 푼다.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  L="$(readlink "$SELF")"
  case "$L" in /*) SELF="$L" ;; *) SELF="$(dirname "$SELF")/$L" ;; esac
done
source "$(cd -P "$(dirname "$SELF")/../lib" && pwd)/common.sh"

RAW=$(gh api graphql -f q="is:pr is:open archived:false author:$ME" -f query='
query($q:String!){
  search(query:$q, type:ISSUE, first:50){
    nodes{ ... on PullRequest {
      number title url createdAt isDraft mergeable
      reviewDecision mergeStateStatus
      repository{ nameWithOwner owner{login} }
      reviews(last:20){ nodes{ author{login} state submittedAt } }
      reviewThreads(last:20){ nodes{
        isResolved isOutdated
        comments(last:5){ nodes{ author{login} createdAt body path } }
      }}
      comments(last:15){ nodes{ author{login} createdAt body } }
    }}
  }
}')

PARSED=$(printf '%s' "$RAW" | jq --arg me "$ME" --arg bots "$BOTS" \
  --argjson skips "$EXCLUDE_OWNERS" --argjson window "$APPROVAL_WINDOW" '
  [ .data.search.nodes[]
    | select(.repository.owner.login | IN($skips[]) | not)
    | select(.isDraft | not)
    | . as $pr
    | ($pr.reviews.nodes | map(select(.state=="APPROVED")) | map(.author.login) | unique) as $approvals
    | ($pr.reviews.nodes | map(select(.state=="CHANGES_REQUESTED")) | map(.author.login) | unique) as $changes
    | ([ $pr.reviewThreads.nodes[]
         | select(.isResolved==false and .isOutdated==false)
         | { path: .comments.nodes[0].path,
             lastBy: .comments.nodes[-1].author.login,
             lastAt: .comments.nodes[-1].createdAt,
             snippet: (.comments.nodes[0].body | gsub("\\s+";" ") | .[0:100]) }
         | select(.lastBy != $me) ]) as $threads
    | ([ $pr.comments.nodes[] | select(.author.login != $me and (.author.login | test($bots) | not)) ] | last) as $lastHuman
    | ([ $pr.comments.nodes[] | select(.author.login == $me) ] | last) as $lastMine
    | {
        repo: $pr.repository.nameWithOwner,
        num: $pr.number, title: $pr.title, url: $pr.url,
        created: $pr.createdAt, mergeable: $pr.mergeable,
        # 승인 개수를 세는 것보다 GitHub 의 판정이 정확하다. 브랜치 보호 규칙의
        # 필요 승인 수까지 반영해 APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED 로 준다.
        reviewDecision: $pr.reviewDecision,
        mergeState: $pr.mergeStateStatus,
        approvals: $approvals, changesRequested: $changes,
        unresolvedThreads: $threads,
        pendingReply: (
          if $lastHuman == null then null
          elif ($lastMine != null and $lastMine.createdAt > $lastHuman.createdAt) then null
          # 같은 사람의 승인이 코멘트와 붙어 있으면 답을 기다리는 코멘트가 아니다.
          elif ([ $pr.reviews.nodes[]
                  | select(.author.login == $lastHuman.author.login and .state == "APPROVED")
                  | select((.submittedAt | fromdateiso8601)
                           >= (($lastHuman.createdAt | fromdateiso8601) - $window)) ] | length) > 0 then null
          else { by: $lastHuman.author.login, at: $lastHuman.createdAt,
                 snippet: ($lastHuman.body | gsub("\\s+";" ") | .[0:140]) }
          end)
      } ]
  | sort_by(.created)')

if [ "${1:-}" = "--json" ]; then printf '%s\n' "$PARSED"; exit 0; fi

printf '%s' "$PARSED" | jq -r '
  def line: "  \(.repo)#\(.num)  \(.title)\n    \(.url)";

  # 한 PR 은 한 구획에만 들어간다. 승인을 받았어도 답할 것이 남았으면 그게 먼저다.
  def needsAction:
    .reviewDecision == "CHANGES_REQUESTED"
    or .pendingReply != null
    or (.unresolvedThreads | length) > 0
    or (.reviewDecision == "APPROVED" and (.mergeState == "DIRTY" or .mergeState == "BEHIND"));
  def reason:
    if .reviewDecision == "CHANGES_REQUESTED" then "변경 요청"
    elif .mergeState == "DIRTY" then "충돌 해결"
    elif .mergeState == "BEHIND" then "브랜치 업데이트"
    elif .pendingReply != null then "답변 필요"
    else "미해결 스레드" end;

  ( [ .[] | select(needsAction) ] ) as $action
  | ( [ .[] | select((needsAction | not) and .reviewDecision == "APPROVED") ] ) as $merge
  | ( [ .[] | select((needsAction | not) and .reviewDecision != "APPROVED") ] ) as $waiting
  | "[1] 리뷰 대기 — \($waiting|length)건",
    ( if ($waiting|length)==0 then "  없음"
      else ($waiting[] | line, "    └ \(.reviewDecision // "리뷰어 없음")")
      end ),
    "",
    "[2] 응답 필요 — \($action|length)건",
    ( if ($action|length)==0 then "  없음"
      else ($action[]
        | line,
          "    └ [\(reason)]",
          ( if .pendingReply != null
            then "    └ \(.pendingReply.by) (\(.pendingReply.at)): \(.pendingReply.snippet)"
            else empty end ),
          ( .unresolvedThreads[] | "    └ [\(.path)] \(.lastBy): \(.snippet)" ))
      end ),
    "",
    "[3] 머지 가능 — \($merge|length)건",
    ( if ($merge|length)==0 then "  없음"
      else ($merge[] | line, "    └ 승인: \(.approvals|join(", "))  / \(.mergeState)")
      end )'
