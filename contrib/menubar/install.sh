#!/usr/bin/env bash
# 메뉴바 앱을 설치하고 로그인 시 자동으로 뜨도록 등록한다.
#
#   install.sh              설치 후 바로 실행
#   install.sh --uninstall  등록 해제 후 venv·런처 삭제
#
# 터미널에서 그냥 실행해도 메뉴바에 뜨지 않는다. macOS 는 GUI 세션에 속한
# 프로세스만 상태 아이템을 그리기 때문이다. 그래서 launchd 에 등록한다.
#
# ~/Applications 에 런처 앱도 둔다. 껐다 다시 켤 때 터미널 없이 Spotlight·
# Launchpad 에서 열 수 있게 하기 위해서다. 런처는 launchd 서비스를 다시 띄울
# 뿐이라 두 개가 겹쳐 뜨지 않는다.
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.pr-myturn.menubar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
VENV="$HERE/.venv"
LOG="$HOME/Library/Logs/pr-menubar.log"
LAUNCHER="$HOME/Applications/PR MyTurn.app"

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$VENV" "$LAUNCHER"
  echo "제거했습니다. 로그는 남아 있습니다: $LOG"
  exit 0
fi

command -v gh >/dev/null || { echo "gh CLI 가 필요합니다: brew install gh" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq 가 필요합니다: brew install jq" >&2; exit 1; }

if [ ! -x "$VENV/bin/python" ]; then
  echo "가상환경을 만듭니다..."
  python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install -q --disable-pip-version-check -r "$HERE/requirements.txt"

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
  <!-- 비정상 종료면 다시 띄우고, 메뉴의 "종료"(정상 종료)면 꺼진 채로 둔다 -->
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin</string></dict>
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

# 런처 앱. 실행 파일은 셸 스크립트 하나다. 서명·빌드를 관리할 필요가 없다.
# LSUIElement 라 Dock 에 아이콘이 남지 않는다.
rm -rf "$LAUNCHER"
mkdir -p "$LAUNCHER/Contents/MacOS"
cat > "$LAUNCHER/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PR MyTurn</string>
  <key>CFBundleIdentifier</key><string>com.pr-myturn.launcher</string>
  <key>CFBundleExecutable</key><string>launch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
cat > "$LAUNCHER/Contents/MacOS/launch" <<EOF
#!/bin/bash
# 메뉴바 앱을 (다시) 띄운다. 등록이 풀려 있으면 다시 등록한다.
launchctl kickstart -k "gui/\$(id -u)/$LABEL" 2>/dev/null \\
  || launchctl bootstrap "gui/\$(id -u)" "$PLIST"
EOF
chmod +x "$LAUNCHER/Contents/MacOS/launch"
plutil -lint "$LAUNCHER/Contents/Info.plist" >/dev/null

echo "설치했습니다. 메뉴바에 'PR' 이 뜨기까지 몇 초 걸립니다."
echo "  로그      $LOG"
echo "  다시 시작 Spotlight 에서 'PR MyTurn' 실행 (= launchctl kickstart -k gui/$UID/$LABEL)"
echo "  제거      $HERE/install.sh --uninstall"
