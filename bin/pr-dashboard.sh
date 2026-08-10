#!/usr/bin/env bash
# 내 PR 현황을 수집해 대시보드 HTML 과 status.json 을 만들고 브라우저로 연다.
#
#   pr-dashboard.sh            # 수집해서 브라우저로 열기
#   pr-dashboard.sh --no-open  # 파일만 갱신 (메뉴바 앱·에이전트용)
#   pr-dashboard.sh --full     # 머지된 PR 답글까지 강제 재수집 (약 20초)
#
# 예전에는 로컬 HTTP 서버를 띄우고 브라우저가 거기에 붙었다. 새로고침만으로
# 재수집이 된다는 이점이 있었지만, 포트 충돌·좀비 프로세스·PATH 의존·DNS
# rebinding 방어 같은 비용을 계속 물었다. 메뉴바 앱이 주기적으로 갱신하게
# 되면서 그 이점이 사라져 서버를 걷어냈다. 지금은 정적 파일 하나가 전부다.
#
# 열린 PR 데이터는 매번 새로 받고, 머지된 PR 의 답글은 느리게 변하므로
# CLOSED_TTL 초 동안 캐시를 재사용한다.
set -euo pipefail

# 캐시에는 비공개 레포의 PR 제목과 리뷰 코멘트 원문이 그대로 담긴다. macOS 홈은
# 그룹(staff)에 읽기 권한이 있어서, 기본 umask 로 두면 같은 머신의 다른 계정이
# 읽을 수 있다. 이 스크립트가 만드는 것은 전부 소유자 전용으로 떨어뜨린다.
umask 077

# 심볼릭 링크로 걸어 써도 lib 를 찾도록 실제 경로를 푼다.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  L="$(readlink "$SELF")"
  case "$L" in /*) SELF="$L" ;; *) SELF="$(dirname "$SELF")/$L" ;; esac
done
BIN="$(cd -P "$(dirname "$SELF")" && pwd)"
LIB="$(cd -P "$BIN/../lib" && pwd)"
source "$LIB/common.sh"

TEMPLATE="$LIB/dashboard.template.html"
OUT="${PR_DASHBOARD_OUT:-$CACHE/dashboard.html}"
CLOSED_CACHE="$CACHE/replies-closed.json"
CLOSED_TTL="${PR_DASHBOARD_CLOSED_TTL:-3600}"
OPEN_TTL="${PR_DASHBOARD_OPEN_TTL:-60}"   # 연타로 GitHub 쿼터를 태우지 않도록

DO_OPEN=true
FORCE_FULL=false
for a in "$@"; do
  case "$a" in
    --no-open) DO_OPEN=false ;;
    --full)    FORCE_FULL=true ;;
    --file)    ;;   # 서버가 없어진 뒤로는 이것이 기본이다. 옛 호출을 깨지 않으려 받아만 둔다
  esac
done

mkdir -p "$CACHE"
chmod 700 "$CACHE" 2>/dev/null || true
find "$CACHE" -maxdepth 1 -type f -exec chmod 600 {} + 2>/dev/null || true

# 파일이 생긴 지 몇 초 지났는지. 없으면 아주 큰 값.
age_of() {
  [ -f "$1" ] || { echo 999999; return; }
  echo $(( $(date +%s) - $(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1") ))
}

out_age=$(age_of "$OUT")
if [ "$FORCE_FULL" != true ] && [ "$out_age" -lt "$OPEN_TTL" ]; then
  printf '최근 %s초 전 데이터를 재사용합니다 (OPEN_TTL=%s).\n' "$out_age" "$OPEN_TTL" >&2
else
  mine=$("$BIN/pr-status.sh" --json)
  replies_open=$("$BIN/pr-review-replies.sh" --json)

  closed_age=$(age_of "$CLOSED_CACHE")
  if [ "$FORCE_FULL" = true ] || [ "$closed_age" -ge "$CLOSED_TTL" ]; then
    "$BIN/pr-review-replies.sh" --closed --json > "$CLOSED_CACHE.tmp" \
      && mv "$CLOSED_CACHE.tmp" "$CLOSED_CACHE"
    closed_age=0
  fi
  [ -f "$CLOSED_CACHE" ] || echo '[]' > "$CLOSED_CACHE"

  # 표시 이름·리마인드 문구 같은 개인 설정은 코드가 아니라 설정 파일에서 온다.
  DATA=$(jq -n \
    --argjson mine "$mine" \
    --argjson open "$replies_open" \
    --argjson closed "$(cat "$CLOSED_CACHE")" \
    --argjson config "$CONFIG" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson closedAge "$closed_age" \
    '{generatedAt: $now, closedAgeSec: $closedAge,
      mine: $mine, reviewedOpen: $open, reviewedClosed: $closed,
      config: { names: ($config.names // {}),
                displayName: ($config.displayName // ""),
                reminderCc: ($config.reminderCc // ""),
                excludeNote: ($config.excludeOwners // [] | join(", ")) }}')

  write_status "$mine" "$replies_open"

  # __DATA__ 치환은 python 으로 한다. sed 는 개행·백슬래시에서 깨진다.
  DATA="$DATA" TEMPLATE="$TEMPLATE" OUT="$OUT" python3 - <<'PY'
import os, pathlib

tpl = pathlib.Path(os.environ["TEMPLATE"]).read_text()
if "__DATA__" not in tpl:
    raise SystemExit("템플릿에 __DATA__ 자리표시자가 없습니다: " + os.environ["TEMPLATE"])

# PR 제목이나 코멘트에 "</script>" 가 있으면 스크립트 블록이 거기서 끊기고
# 뒤가 HTML 로 파싱된다. JSON 문자열 안의 < 는 "<" 로 디코딩되므로
# 표시에는 영향이 없고 태그만 만들어지지 않는다. U+2028/2029 는 JS 에서
# 줄바꿈으로 취급되어 리터럴을 깨뜨리므로 같이 막는다.
data = (os.environ["DATA"]
        .replace("<", "\\u003c")
        .replace(" ", "\\u2028")
        .replace(" ", "\\u2029"))

pathlib.Path(os.environ["OUT"]).write_text(tpl.replace("__DATA__", data, 1))
PY

  printf '갱신 — 내 PR %s건, 내 리뷰 답글 %s건 (머지분 캐시 %s초 전)\n' \
    "$(printf '%s' "$mine" | jq 'length')" \
    "$(printf '%s' "$replies_open" | jq 'length')" \
    "$closed_age" >&2
fi

if [ "$DO_OPEN" = true ]; then
  open "$OUT"
fi
