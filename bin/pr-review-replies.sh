#!/usr/bin/env bash
# 내가 리뷰어로 코멘트를 남긴 PR 중, 리뷰이(작성자)가 답글을 달아 내 확인이 필요한 건을 추출한다.
#   - 내가 참여한 리뷰 스레드에서 마지막 발언이 내가 아닌 경우
#   - 미해결(unresolved) 스레드를 우선 표시, 해결된 스레드는 --all 일 때만
# 내가 작성자인 PR 은 제외한다.
#
# usage: pr-review-replies.sh [--all] [--json] [--closed]
set -euo pipefail

# 심볼릭 링크로 걸어 써도 lib 를 찾도록 실제 경로를 푼다.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  L="$(readlink "$SELF")"
  case "$L" in /*) SELF="$L" ;; *) SELF="$(dirname "$SELF")/$L" ;; esac
done
source "$(cd -P "$(dirname "$SELF")/../lib" && pwd)/common.sh"

SHOW_ALL=false
OUT_JSON=false
SCOPE='is:open'
for a in "$@"; do
  case "$a" in
    --all) SHOW_ALL=true ;;
    --json) OUT_JSON=true ;;
    --closed) SCOPE="is:closed updated:>$CLOSED_SINCE" ;;
  esac
done

QUERY='
query($q:String!,$cursor:String){
  search(query:$q, type:ISSUE, first:25, after:$cursor){
    issueCount
    pageInfo{ hasNextPage endCursor }
    nodes{ ... on PullRequest {
      number title url updatedAt isDraft
      author{login}
      repository{ nameWithOwner owner{login} }
      reviewThreads(last:30){ nodes{
        isResolved isOutdated
        comments(first:10){ nodes{ author{login} createdAt body path url } }
      }}
      comments(last:15){ nodes{ author{login} createdAt body url } }
    }}
  }
}'

# GitHub search 는 한 번에 25건씩 받아 hasNextPage 를 따라 끝까지 순회한다.
# (페이지를 키우면 중첩 커넥션 때문에 GraphQL 쿼터가 급격히 는다)
# (한계: search API 자체가 1000건까지만 반환한다. 그 이상이면 기간을 좁힐 것)
fetch() {
  local q="$1" cursor="" page
  while :; do
    if [ -z "$cursor" ]; then
      page=$(gh api graphql -f q="$q" -f query="$QUERY" 2>/dev/null) || break
    else
      page=$(gh api graphql -f q="$q" -F cursor="$cursor" -f query="$QUERY" 2>/dev/null) || break
    fi
    printf '%s' "$page" | jq -c '.data.search.nodes[]? | select(. != {})'
    [ "$(printf '%s' "$page" | jq -r '.data.search.pageInfo.hasNextPage')" = "true" ] || break
    cursor=$(printf '%s' "$page" | jq -r '.data.search.pageInfo.endCursor')
  done
}

# 두 검색은 서로를 기다릴 이유가 없다. 각각 0.7초쯤 걸리므로 나란히 돌린다.
# (하나의 GraphQL 요청에 search 를 여러 개 넣어보기도 했는데, GitHub 이 그것을
#  순차로 처리해서 오히려 느렸다. 병렬 HTTP 요청이 낫다.)
raw_a="$CACHE/.replies-a.$$"; raw_b="$CACHE/.replies-b.$$"
mkdir -p "$CACHE"
trap 'rm -f "$raw_a" "$raw_b"' EXIT
fetch "is:pr $SCOPE archived:false reviewed-by:$ME -author:$ME" > "$raw_a" &
pid_a=$!
fetch "is:pr $SCOPE archived:false commenter:$ME -author:$ME" > "$raw_b" &
pid_b=$!
wait "$pid_a"; wait "$pid_b"
RAW=$(cat "$raw_a" "$raw_b" | jq -s 'unique_by(.url)')

PARSED=$(printf '%s' "$RAW" | jq --arg me "$ME" --arg bots "$BOTS" \
  --argjson skips "$EXCLUDE_OWNERS" --argjson all "$SHOW_ALL" '
  [ .[]
    | select(.repository.owner.login | IN($skips[]) | not)
    | select(.isDraft | not)
    | . as $pr
    | { repo: $pr.repository.nameWithOwner, num: $pr.number, title: $pr.title,
        url: $pr.url, author: $pr.author.login, updated: $pr.updatedAt,
        threads: [ $pr.reviewThreads.nodes[]
          | select(.isOutdated == false)
          | select($all or (.isResolved == false))
          | . as $t
          | select([ $t.comments.nodes[].author.login ] | index($me))
          | ($t.comments.nodes | last) as $last
          | select($last.author.login != $me)
          | select($last.author.login | test($bots) | not)
          | { path: $t.comments.nodes[0].path,
              resolved: $t.isResolved,
              myPoint: ([ $t.comments.nodes[] | select(.author.login == $me) ] | last
                        | .body | gsub("\\s+";" ") | .[0:110]),
              replyBy: $last.author.login,
              replyAt: $last.createdAt,
              reply: ($last.body | gsub("\\s+";" ") | .[0:150]),
              link: $last.url } ] }
    | select((.threads | length) > 0) ]
  | sort_by(.updated) | reverse')

if [ "$OUT_JSON" = true ]; then printf '%s\n' "$PARSED"; exit 0; fi

printf '%s' "$PARSED" | jq -r '
  if length == 0 then "내 리뷰에 달린 미확인 응답이 없습니다."
  else
    "내 리뷰 코멘트에 응답이 달린 PR — \(length)건\n",
    (.[] | "\(.repo)#\(.num)  \(.title)\n  작성자: \(.author)  \(.url)",
      (.threads[] | "  [\(.path // "-")]\(if .resolved then " (resolved)" else "" end)\n    나: \(.myPoint)\n    \(.replyBy) (\(.replyAt)): \(.reply)\n    \(.link)"),
      "")
  end'
