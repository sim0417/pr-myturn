#!/usr/bin/env python3
"""메뉴바에 "지금 내 차례인 PR" 건수를 띄운다.

대시보드를 열어봐야 아는 정보를 상시로 보이게 하는 것이 전부다. 수집은
bin/pr-status.sh 를 그대로 호출하므로 판정 로직이 대시보드와 어긋나지 않는다.

    python3 contrib/menubar/app.py

내 차례 = 응답 필요(내가 답할 것) + 머지 대기(내가 머지할 것).
리뷰 대기는 상대 차례이므로 배지에 넣지 않고 메뉴에서만 보여준다.
"""
import json
import os
import pathlib
import subprocess
import time

import rumps

from window import DashboardWindow

REPO = pathlib.Path(__file__).resolve().parents[2]
STATUS = REPO / "bin" / "pr-status.sh"
DASHBOARD = REPO / "bin" / "pr-dashboard.sh"

# 수집할 때마다 여기에도 써 둔다. 에이전트는 GitHub 을 다시 부르지 않고 이 파일만
# 읽으면 된다. 대시보드를 빌드할 때는 pr-dashboard.sh 가 리뷰 답글까지 채워 덮어쓴다.
CACHE = pathlib.Path(
    os.environ.get("PR_MYTURN_CACHE")
    or pathlib.Path(os.environ.get("XDG_CACHE_HOME", pathlib.Path.home() / ".cache")) / "pr-myturn")
STATUS_JSON = CACHE / "status.json"
DASHBOARD_HTML = CACHE / "dashboard.html"

# GUI 로 띄우면 로그인 셸의 PATH 를 물려받지 못해 gh 나 jq 를 찾지 못한다.
# /usr/sbin 도 넣는다. lsof 같은 도구가 거기 있고, 빠지면 하위 스크립트가
# 조용히 다른 길로 새기 때문이다.
ENV = {**os.environ, "PATH": os.pathsep.join(
    ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin",
     os.environ.get("PATH", "")])}

CONFIG_PATH = pathlib.Path(
    os.environ.get("PR_DASHBOARD_CONFIG")
    or pathlib.Path(os.environ.get("XDG_CONFIG_HOME", pathlib.Path.home() / ".config"))
    / "pr-dashboard" / "config.json")


def config():
    try:
        return json.loads(CONFIG_PATH.read_text())
    except (OSError, ValueError):
        return {}


def notify(title, message):
    """rumps 의 알림은 앱 번들 없이는 뜨지 않으므로 osascript 로 띄운다."""
    body = json.dumps(message)[1:-1]
    head = json.dumps(title)[1:-1]
    subprocess.run(
        ["osascript", "-e", f'display notification "{body}" with title "{head}"'],
        capture_output=True)


class Dashboard(rumps.App):
    def __init__(self):
        super().__init__("PR", quit_button="종료")
        self.poll_sec = int(config().get("menubarPollSec", 300))
        self.prs = []
        self.error = None
        self.fetched_at = None
        self.last_pending = None      # 알림은 "늘어났을 때"만 띄우기 위한 직전 값
        self.window = DashboardWindow()
        self.timer = rumps.Timer(self.tick, self.poll_sec)
        self.timer.start()
        self.tick(None)

    # 수집 --------------------------------------------------------------

    def tick(self, _):
        try:
            out = subprocess.run(
                [str(STATUS), "--json"], env=ENV, capture_output=True,
                text=True, timeout=60, check=True).stdout
            self.prs = json.loads(out)
            self.error = None
            self.write_status()
        except subprocess.CalledProcessError as e:
            self.error = (e.stderr or "").strip().splitlines()[-1:] or ["수집 실패"]
            self.error = self.error[0][:80]
        except subprocess.TimeoutExpired:
            self.error = "수집이 60초를 넘어 중단했습니다"
        except (OSError, ValueError) as e:
            self.error = str(e)[:80]

        self.fetched_at = time.localtime()
        self.render()

    def write_status(self):
        """에이전트가 읽는 파일. 5분마다 최신으로 유지된다.

        리뷰 답글(reviewedOpen)은 수집이 무거워 여기서는 채우지 않는다.
        대시보드를 열면 pr-dashboard.sh 가 그것까지 채워 덮어쓴다.
        """
        payload = {
            "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "counts": {
                "action": len(self.need_reply),
                "merge": len(self.ready_to_merge),
                "waiting": len(self.waiting),
                "reviewReplies": None,
            },
            "mine": self.prs,
            "reviewedOpen": None,
        }
        try:
            CACHE.mkdir(parents=True, exist_ok=True)
            CACHE.chmod(0o700)
            tmp = STATUS_JSON.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2))
            tmp.chmod(0o600)
            tmp.replace(STATUS_JSON)
        except OSError:
            pass          # 배지를 띄우는 일이 더 중요하다. 여기서 앱을 멈추지 않는다

    # 분류 --------------------------------------------------------------

    # 분류는 pr-status.sh 가 이미 끝냈다. 여기서 다시 판정하지 않는다.
    # 판정을 두 벌 두면 언젠가 어긋나고, 어긋난 쪽을 찾기가 어렵다.
    def in_bucket(self, name):
        return [p for p in self.prs if p.get("bucket") == name]

    @staticmethod
    def action_reason(p):
        return p.get("reason") or ""

    @property
    def need_reply(self):
        return self.in_bucket("action")

    @property
    def ready_to_merge(self):
        return self.in_bucket("merge")

    @property
    def waiting(self):
        return self.in_bucket("waiting")

    # 표시 --------------------------------------------------------------

    def render(self):
        if self.error:
            self.title = "PR ?"
        else:
            mine = len(self.need_reply) + len(self.ready_to_merge)
            self.title = f"PR {mine}" if mine else "PR"
            self.announce(len(self.need_reply))

        self.menu.clear()
        items = []

        if self.error:
            items.append(rumps.MenuItem(f"수집 실패 — {self.error}"))
        else:
            items += self.section("내 차례", self.need_reply, self.action_reason)
            items += self.section("머지 가능", self.ready_to_merge)
            items += self.section("리뷰 대기", self.waiting)
            if not self.prs:
                items.append(rumps.MenuItem("열린 PR 이 없습니다"))

        items.append(rumps.separator)
        items.append(rumps.MenuItem("대시보드 열기", callback=self.open_dashboard))
        items.append(rumps.MenuItem("지금 새로고침", callback=self.tick))
        if self.fetched_at:
            stamp = time.strftime("%H:%M", self.fetched_at)
            items.append(rumps.MenuItem(f"마지막 갱신 {stamp}"))
        self.menu = items

    def section(self, label, prs, reason=None):
        """구획 제목과 그 아래 PR 항목들. 항목을 누르면 그 PR 을 연다."""
        if not prs:
            return []
        out = [rumps.MenuItem(f"{label} {len(prs)}건")]
        for p in prs:
            title = p["title"]
            if len(title) > 52:
                title = title[:51] + "…"
            tag = f"[{reason(p)}] " if reason else ""
            item = rumps.MenuItem(f"    {p['repo'].split('/')[-1]}#{p['num']}  {tag}{title}",
                                  callback=self.open_pr)
            item.pr_url = p["url"]
            out.append(item)
        out.append(rumps.separator)
        return out

    def announce(self, pending):
        """답변 필요가 늘어난 순간에만 알린다. 같은 건으로 반복해 알리지 않는다."""
        if self.last_pending is not None and pending > self.last_pending:
            notify("답변을 기다리는 PR", f"{pending}건 — 메뉴바에서 확인하세요")
        self.last_pending = pending

    # 동작 --------------------------------------------------------------

    def open_pr(self, sender):
        subprocess.run(["open", sender.pr_url], env=ENV)

    def open_dashboard(self, _):
        """수집해서 HTML 을 갱신한 뒤 앱 창에 띄운다.

        수집은 리뷰 답글까지 훑느라 몇 초 걸리므로 창을 먼저 띄우고 싶지만,
        그러면 옛 화면이 잠깐 보였다가 바뀐다. 짧은 대기가 덜 거슬린다.
        """
        try:
            # 출력을 버리지 않는다. 실패하면 launchd 로그에 남아야 한다.
            subprocess.run([str(DASHBOARD), "--no-open"], env=ENV,
                           timeout=120, check=True)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
            # 수집이 어긋나도 직전 화면은 보여준다. 아무것도 안 뜨는 것보다 낫다.
            print(f"대시보드 갱신 실패, 이전 화면을 띄웁니다: {e}", flush=True)

        try:
            self.window.show(DASHBOARD_HTML)
        except FileNotFoundError:
            notify("대시보드를 열 수 없습니다", "수집이 한 번도 끝나지 않았습니다")


def hide_dock_icon():
    """메뉴바에만 살고 Dock 에는 나타나지 않게 한다.

    앱 번들이라면 Info.plist 의 LSUIElement 로 할 일이지만, 스크립트로 바로
    실행하는 쪽이 설치가 간단해서 실행 시점에 활성화 정책을 바꾼다.
    """
    from AppKit import NSApplication, NSApplicationActivationPolicyAccessory
    NSApplication.sharedApplication().setActivationPolicy_(
        NSApplicationActivationPolicyAccessory)


if __name__ == "__main__":
    hide_dock_icon()
    Dashboard().run()
