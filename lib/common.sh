#!/usr/bin/env bash
# 세 스크립트가 공유하는 설정 로딩.
#
# 설정 파일은 없어도 된다. 없으면 표시 이름은 GitHub 로그인 그대로 쓰고,
# 제외 목록은 비어 있는 상태로 동작한다. 개인 정보를 코드에 두지 않기 위한 구조다.
#
# 탐색 순서:
#   $PR_DASHBOARD_CONFIG
#   $XDG_CONFIG_HOME/pr-dashboard/config.json
#   ~/.config/pr-dashboard/config.json

CONFIG_PATH="${PR_DASHBOARD_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/pr-dashboard/config.json}"

if [ -f "$CONFIG_PATH" ]; then
  if ! CONFIG=$(jq -e . "$CONFIG_PATH" 2>&1); then
    printf '설정 파일을 읽을 수 없습니다: %s\n%s\n' "$CONFIG_PATH" "$CONFIG" >&2
    exit 1
  fi
else
  CONFIG='{}'
fi

# 설정에서 값을 꺼낸다. 없으면 두 번째 인자를 기본값으로 쓴다.
cfg() { printf '%s' "$CONFIG" | jq -r --arg d "$2" ".$1 // \$d"; }

ME=$(gh api user --jq '.login')

# 봇 로그인은 정규식으로 한 번에 거른다. 설정에 배열로 두고 여기서 조립한다.
BOTS=$(printf '%s' "$CONFIG" | jq -r '
  (.bots // ["github-actions","dependabot","codecov","renovate"]) | join("|")')

# 집계에서 뺄 소유자(개인 레포 등). 배열이며 비어 있으면 아무것도 빼지 않는다.
EXCLUDE_OWNERS=$(printf '%s' "$CONFIG" | jq -c '.excludeOwners // []')

# 머지된 PR 을 얼마나 거슬러 볼지. GitHub search 의 updated: 한정자로 쓴다.
CLOSED_WITHIN_DAYS=$(cfg closedWithinDays 30)
CLOSED_SINCE=$(date -u -v-"${CLOSED_WITHIN_DAYS}"d +%Y-%m-%d 2>/dev/null \
  || date -u -d "${CLOSED_WITHIN_DAYS} days ago" +%Y-%m-%d)

# 승인 버튼과 "LGTM" 코멘트를 따로 남기는 리뷰어가 있다. 둘은 몇 초 차이로 오고
# 순서도 그때그때 다르므로, 승인 전후 이 시간(초) 안의 코멘트는 승인의 일부로 본다.
# 승인하고 한참 뒤에 달린 코멘트는 진짜 질문일 수 있으므로 응답 필요로 남긴다.
APPROVAL_WINDOW=$(cfg approvalWindowSec 600)
