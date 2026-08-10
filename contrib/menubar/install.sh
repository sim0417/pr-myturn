#!/usr/bin/env bash
# 메뉴바 앱을 설치하고 로그인 시 자동으로 뜨도록 등록한다.
#
#   install.sh              설치 후 바로 실행
#   install.sh --uninstall  등록 해제 후 venv 삭제
#
# 터미널에서 그냥 실행해도 메뉴바에 뜨지 않는다. macOS 는 GUI 세션에 속한
# 프로세스만 상태 아이템을 그리기 때문이다. 그래서 launchd 에 등록한다.
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.gh-pr-dashboard.menubar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
VENV="$HERE/.venv"
LOG="$HOME/Library/Logs/pr-menubar.log"

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$VENV"
  echo "제거했습니다. 로그는 남아 있습니다: $LOG"
  exit 0
fi

command -v gh >/dev/null || { echo "gh CLI 가 필요합니다: brew install gh" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq 가 필요합니다: brew install jq" >&2; exit 1; }

if [ ! -x "$VENV/bin/python" ]; then
  echo "가상환경을 만듭니다..."
  python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install -q --disable-pip-version-check --upgrade rumps

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$VENV/bin/python</string>
    <string>$HERE/app.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
</dict>
</plist>
EOF

plutil -lint "$PLIST" >/dev/null

# bootout 은 비동기다. 서비스가 사라지기 전에 bootstrap 하면 5: I/O error 가 난다.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
for _ in $(seq 1 40); do
  launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || break
  sleep 0.25
done
launchctl bootstrap "gui/$UID" "$PLIST"

echo "설치했습니다. 메뉴바에 'PR' 이 뜨기까지 몇 초 걸립니다."
echo "  로그      $LOG"
echo "  다시 시작 launchctl kickstart -k gui/$UID/$LABEL"
echo "  제거      $HERE/install.sh --uninstall"
