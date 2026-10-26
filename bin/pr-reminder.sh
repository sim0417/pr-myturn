#!/usr/bin/env bash
# 슬랙 리마인드 문구를 status.json 에서 만든다. GitHub 을 다시 부르지 않는다.
#
#   pr-reminder.sh          # 리뷰 대기 리마인드 평문
#   pr-reminder.sh --ready  # 머지 가능 문구 평문
#   pr-reminder.sh --json   # {wait, ready} 각각 {count, text, html}
#
# 메뉴바 앱이 복사할 때 부른다. 설정은 매번 새로 읽으므로 제외 저장소를 바꾸면
# 재수집 없이 바로 반영된다. 문구 자체는 lib/reminder.jq 가 만든다.
set -euo pipefail

SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  L="$(readlink "$SELF")"
  case "$L" in /*) SELF="$L" ;; *) SELF="$(dirname "$SELF")/$L" ;; esac
done
LIB="$(cd -P "$(dirname "$SELF")/../lib" && pwd)"
source "$LIB/common.sh"

[ -f "$STATUS_JSON" ] || { echo "status.json 이 없습니다. pr-dashboard.sh --no-open 을 먼저 돌리세요." >&2; exit 1; }

out=$(jq --argjson config "$CONFIG" '{mine: .mine, config: $config}' "$STATUS_JSON" \
      | jq -f "$LIB/reminder.jq")

case "${1:-}" in
  --json)  printf '%s\n' "$out" ;;
  --ready) printf '%s' "$out" | jq -r '.ready.text // empty' ;;
  *)       printf '%s' "$out" | jq -r '.wait.text // empty' ;;
esac
