#!/usr/bin/env bash
# 나에게 리뷰가 요청된 열린 PR 을 뽑는다. 상대가 나를 기다리고 있는 건이다.
#
# pr-review-replies.sh 는 "내가 이미 코멘트한 PR" 만 본다. 1차 리뷰를 에이전트에
# 맡기면 내가 아직 손대지 않은 PR 이 생기는데, 그런 PR 은 어디에도 잡히지 않았다.
# 리뷰를 제출하면 GitHub 이 요청을 지우므로 여기서도 저절로 빠진다.
#
# 팀 단위 요청은 세지 않는다(user-review-requested). 팀원 누구나 받을 수 있는
# 요청까지 넣으면 "내 차례" 가 흐려진다.
#
# usage: pr-review-requests.sh [--json]
set -euo pipefail

# 심볼릭 링크로 걸어 써도 lib 를 찾도록 실제 경로를 푼다.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  L="$(readlink "$SELF")"
  case "$L" in /*) SELF="$L" ;; *) SELF="$(dirname "$SELF")/$L" ;; esac
done
source "$(cd -P "$(dirname "$SELF")/../lib" && pwd)/common.sh"

RAW=$(gh api graphql -f q="is:pr is:open archived:false draft:false user-review-requested:$ME -author:$ME" -f query='
query($q:String!){
  search(query:$q, type:ISSUE, first:50){
    nodes{ ... on PullRequest {
      number title url createdAt
      author{login}
      repository{ nameWithOwner owner{login} }
      timelineItems(itemTypes:[REVIEW_REQUESTED_EVENT], last:10){ nodes{
        ... on ReviewRequestedEvent{ createdAt requestedReviewer{ ... on User{login} } }
      }}
      reviewThreads(last:30){ nodes{ isResolved isOutdated } }
    }}
  }
}')

PARSED=$(printf '%s' "$RAW" | jq --arg me "$ME" --arg bots "$BOTS" \
  --argjson skips "$EXCLUDE_OWNERS" '
  [ .data.search.nodes[]
    | select(.repository.owner.login | IN($skips[]) | not)
    | select(.author.login | test($bots) | not)
    | . as $pr
    | { repo: $pr.repository.nameWithOwner,
        num: $pr.number, title: $pr.title, url: $pr.url,
        author: $pr.author.login, created: $pr.createdAt,
        # 대기는 PR 을 연 시점이 아니라 나에게 요청이 온 시점부터 센다.
        # 다시 요청되면 가장 최근 것을 쓴다.
        requestedAt: ([ $pr.timelineItems.nodes[]
                        | select(.requestedReviewer.login? == $me) | .createdAt ]
                      | last // $pr.createdAt),
        # 에이전트 1차 리뷰가 남긴 지적이 여기에 잡힌다. 볼 거리가 얼마나 되는지 가늠용.
        unresolvedThreads: ([ $pr.reviewThreads.nodes[]
                              | select(.isResolved == false and .isOutdated == false) ]
                            | length) } ]
  | sort_by(.requestedAt)')

if [ "${1:-}" = "--json" ]; then printf '%s\n' "$PARSED"; exit 0; fi

printf '%s' "$PARSED" | jq -r '
  if length == 0 then "나에게 요청된 리뷰가 없습니다."
  else
    "리뷰 요청 — \(length)건",
    (.[] | "  \(.repo)#\(.num)  \(.title)",
           "    작성자 \(.author) · 요청 \(.requestedAt) · 미해결 스레드 \(.unresolvedThreads)",
           "    \(.url)")
  end'
