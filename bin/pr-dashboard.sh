#!/usr/bin/env bash
# 내 PR 현황 대시보드를 최신 데이터로 만들어 브라우저에 띄운다.
#
#   pr-dashboard.sh            # 서버를 띄우고 브라우저로 열기 (새로고침 = 재수집)
#   pr-dashboard.sh --stop     # 백그라운드 서버 종료
#   pr-dashboard.sh --file     # 서버 없이 정적 파일로만 열기
#   pr-dashboard.sh --no-open  # 파일만 갱신
#   pr-dashboard.sh --full     # 머지된 PR 답글까지 강제 재수집 (약 20초)
#   pr-dashboard.sh --serve    # 서버를 포그라운드로 실행 (Ctrl+C 종료)
#
# 기본이 서버인 이유: file:// 로 열면 클립보드 복사가 브라우저에 막힐 수 있고,
# 새로고침만으로 최신 데이터를 받을 수 없다.
#
# 열린 PR 데이터는 매번 새로 받고, 머지된 PR 의 답글은 느리게 변하므로
# CLOSED_TTL 초 동안 캐시를 재사용한다.
set -euo pipefail

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
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/pr-dashboard"
OUT="${PR_DASHBOARD_OUT:-$CACHE/dashboard.html}"
CLOSED_CACHE="$CACHE/replies-closed.json"
CLOSED_TTL="${PR_DASHBOARD_CLOSED_TTL:-3600}"
OPEN_TTL="${PR_DASHBOARD_OPEN_TTL:-60}"   # 새로고침 연타로 GitHub 쿼터를 태우지 않도록
PORT="${PR_DASHBOARD_PORT:-8787}"

DO_OPEN=true
DO_SERVE=false
FORCE_FULL=false
FILE_MODE=false
DO_STOP=false
for a in "$@"; do
  case "$a" in
    --no-open) DO_OPEN=false; FILE_MODE=true ;;
    --full)    FORCE_FULL=true ;;
    --serve)   DO_SERVE=true; DO_OPEN=false ;;
    --file)    FILE_MODE=true ;;
    --stop)    DO_STOP=true ;;
  esac
done

PIDFILE="$CACHE/server.pid"

# macOS 의 `nc -z` 는 닫힌 포트에도 0 을 반환하는 경우가 있어 lsof 로 확인한다.
# curl 로 찔러보는 방식은 요청마다 재수집이 돌아 5초씩 걸리므로 쓰지 않는다.
server_up() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; }

mkdir -p "$CACHE"

if [ "$DO_STOP" = true ]; then
  if [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null; then
    rm -f "$PIDFILE"
    echo "대시보드 서버를 종료했습니다 (포트 $PORT)."
  else
    rm -f "$PIDFILE"
    echo "실행 중인 대시보드 서버가 없습니다."
  fi
  exit 0
fi

# 파일이 생긴 지 몇 초 지났는지. 없으면 아주 큰 값.
age_of() {
  [ -f "$1" ] || { echo 999999; return; }
  echo $(( $(date +%s) - $(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1") ))
}

build() {
  local mine replies_open closed_age out_age

  # 직전 빌드가 충분히 최신이면 GitHub 을 다시 부르지 않는다.
  out_age=$(age_of "$OUT")
  if [ "$FORCE_FULL" != true ] && [ "$out_age" -lt "$OPEN_TTL" ]; then
    printf '최근 %s초 전 데이터를 재사용합니다 (OPEN_TTL=%s).\n' "$out_age" "$OPEN_TTL" >&2
    return 0
  fi

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
        .replace("\u2028", "\\u2028")
        .replace("\u2029", "\\u2029"))

pathlib.Path(os.environ["OUT"]).write_text(tpl.replace("__DATA__", data, 1))
PY

  printf '갱신 — 내 PR %s건, 내 리뷰 답글 %s건 (머지분 캐시 %s초 전)\n' \
    "$(printf '%s' "$mine" | jq 'length')" \
    "$(printf '%s' "$replies_open" | jq 'length')" \
    "$closed_age" >&2
}

if [ "$DO_SERVE" = true ]; then
  export PR_DASHBOARD_OUT="$OUT"
  echo "http://localhost:$PORT — 새로고침하면 다시 수집합니다. Ctrl+C 로 종료." >&2
  BIN="$BIN" OUT="$OUT" PORT="$PORT" python3 - <<'PY'
import http.server, os, pathlib, subprocess, socketserver

OUT = pathlib.Path(os.environ["OUT"])
PORT = int(os.environ["PORT"])
BUILD = [str(pathlib.Path(os.environ["BIN"]) / "pr-dashboard.sh"), "--no-open"]

# 루프백에만 바인딩해도 브라우저는 어떤 페이지에서든 이 주소로 요청을 보낼 수 있다.
# 악성 사이트가 자기 도메인을 127.0.0.1 로 재바인딩하면(DNS rebinding) 동일 출처
# 정책을 우회해 여기 응답을 읽어간다. Host 헤더를 제한해 그 경로를 막는다.
ALLOWED_HOSTS = {f"localhost:{PORT}", f"127.0.0.1:{PORT}", f"[::1]:{PORT}"}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Host", "") not in ALLOWED_HOSTS:
            self.send_error(403, "Host not allowed"); return
        if self.path not in ("/", "/index.html"):
            self.send_error(404); return
        try:
            subprocess.run(BUILD, check=True, stdout=subprocess.DEVNULL)
        except subprocess.CalledProcessError as e:
            # GitHub 쿼터 초과 등으로 수집이 실패해도, 직전 결과가 있으면 그것이라도 보여준다.
            if not OUT.exists():
                self.send_error(503, "수집 실패, 이전 결과도 없습니다"); return
            print(f"수집 실패, 이전 결과를 내보냅니다: {e}", flush=True)
        body = OUT.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *a):
        pass

class Server(socketserver.TCPServer):
    allow_reuse_address = True

with Server(("127.0.0.1", PORT), Handler) as httpd:
    httpd.serve_forever()
PY
  exit 0
fi

if [ "$FILE_MODE" = true ]; then
  build
  [ "$DO_OPEN" = true ] && open "$OUT"
  exit 0
fi

# 기본 경로: 서버가 없으면 백그라운드로 띄우고 브라우저를 연다.
if server_up; then
  echo "이미 실행 중인 서버를 재사용합니다 — http://localhost:$PORT" >&2
else
  nohup "$BIN/pr-dashboard.sh" --serve >"$CACHE/server.log" 2>&1 &
  echo $! > "$PIDFILE"
  for _ in $(seq 1 40); do
    server_up && break
    sleep 0.25
  done
  if ! server_up; then
    echo "서버를 띄우지 못했습니다. 로그: $CACHE/server.log" >&2
    exit 1
  fi
  echo "서버 시작 — http://localhost:$PORT (종료: pr-dashboard.sh --stop)" >&2
fi

[ "$DO_OPEN" = true ] && open "http://localhost:$PORT/"
exit 0
