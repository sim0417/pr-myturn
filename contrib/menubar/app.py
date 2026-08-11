#!/usr/bin/env python3
"""메뉴바에 "지금 내 차례인 PR" 건수를 띄운다.

대시보드를 열어봐야 아는 정보를 상시로 보이게 한다. 주기적으로 깨어날 때
bin/pr-dashboard.sh 를 그대로 호출해 배지·status.json·대시보드 HTML 을 한꺼번에
만들어 둔다. 판정 로직을 따로 두지 않고, 창을 열 때 기다릴 일도 없앤다.

    python3 contrib/menubar/app.py

내 차례 = 응답 필요(내가 답할 것) + 머지 대기(내가 머지할 것).
리뷰 대기는 상대 차례이므로 배지에 넣지 않고 메뉴에서만 보여준다.
"""
import json
import os
import pathlib
import subprocess
import threading
import time

import rumps
from PyObjCTools import AppHelper

from window import DashboardWindow

REPO = pathlib.Path(__file__).resolve().parents[2]
DASHBOARD = REPO / "bin" / "pr-dashboard.sh"

# 산출물은 전부 pr-dashboard.sh 가 쓴다. 앱은 배지를 그리려고 status.json 을
# 읽고, 창에는 dashboard.html 을 띄운다.
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
        self.collecting = False
        self.building = False
        self.window = DashboardWindow(on_refresh=self.refresh_dashboard)
        self.timer = rumps.Timer(self.tick, self.poll_sec)
        self.timer.start()
        self.tick(None)

    # 수집 --------------------------------------------------------------
    #
    # rumps 의 타이머와 메뉴 콜백은 UI 스레드에서 돈다. 여기서 수집을 기다리면
    # 그 몇 초 동안 메뉴바가 통째로 얼어붙고 창도 뜨지 못한다. 수집은 항상
    # 별도 스레드에서 하고, 화면을 건드리는 일만 메인 스레드로 되돌린다.

    def tick(self, _):
        if self.collecting:
            return          # 앞선 수집이 아직이면 겹쳐 부르지 않는다
        self.collecting = True
        threading.Thread(target=self._collect, daemon=True).start()

    def _collect(self):
        """대시보드까지 통째로 만들어 둔다.

        예전에는 배지에 필요한 만큼만(pr-status) 받고 HTML 은 열 때 만들었다.
        그래서 창을 열 때마다 몇 초를 기다려야 했다. 어차피 주기적으로 깨어나는
        김에 화면까지 만들어 두면, 열었을 때 기다릴 일이 없다.
        """
        try:
            # 폴링 주기가 곧 수집 주기가 되도록 OPEN_TTL 을 눌러둔다. 그러지 않으면
            # menubarPollSec 을 60초 밑으로 줄여도 스크립트가 캐시를 재사용해
            # 설정이 먹지 않는다. 연타 방어는 collecting 플래그가 한다.
            subprocess.run([str(DASHBOARD), "--no-open"],
                           env={**ENV, "PR_DASHBOARD_OPEN_TTL": "0"},
                           capture_output=True, text=True, timeout=180, check=True)
            prs = json.loads(STATUS_JSON.read_text())["mine"]
            error = None
        except subprocess.CalledProcessError as e:
            prs = None
            tail = (e.stderr or "").strip().splitlines()[-1:]
            error = (tail[0] if tail else "수집 실패")[:80]
        except subprocess.TimeoutExpired:
            prs, error = None, "수집이 180초를 넘어 중단했습니다"
        except (OSError, ValueError, KeyError) as e:
            prs, error = None, str(e)[:80]

        AppHelper.callAfter(self._collected, prs, error)

    def _collected(self, prs, error):
        """메인 스레드. 여기서만 상태와 화면을 만진다."""
        self.collecting = False
        self.error = error
        if prs is not None:
            self.prs = prs
            # 창이 떠 있으면 새 내용으로 갈아끼운다. 앞으로 끌어내지는 않는다.
            self.window.reload(DASHBOARD_HTML)
        self.fetched_at = time.localtime()
        self.render()

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
        """있는 화면을 바로 띄우고, 갱신은 뒤에서 한다.

        수집을 기다렸다 띄우면 5초쯤 아무 일도 일어나지 않는 것처럼 보인다.
        먼저 보여주고 새 데이터가 오면 바꾸는 편이 훨씬 빠르게 느껴진다.
        """
        if DASHBOARD_HTML.is_file():
            self.window.show(DASHBOARD_HTML)
        self.refresh_dashboard()

    def refresh_dashboard(self):
        """페이지의 새로고침 버튼과 대시보드 열기가 함께 쓰는 입구."""
        if self.building:
            return          # 이미 돌고 있으면 두 번 걸지 않는다
        self.building = True
        threading.Thread(target=self._rebuild_dashboard, daemon=True).start()

    def _rebuild_dashboard(self):
        ok = True
        try:
            # OPEN_TTL 을 0 으로 눌러 캐시를 건너뛴다. 사람이 새로고침을 눌렀는데
            # "60초 안에 받은 게 있으니 그대로" 라고 답하면 고장으로 보인다.
            # 연타는 building 플래그가 막으므로 쿼터가 새지 않는다.
            # 출력을 버리지 않는다. 실패하면 launchd 로그에 남아야 한다.
            subprocess.run([str(DASHBOARD), "--no-open"],
                           env={**ENV, "PR_DASHBOARD_OPEN_TTL": "0"},
                           timeout=180, check=True)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
            ok = False
            print(f"대시보드 갱신 실패: {e}", flush=True)
        AppHelper.callAfter(self._rebuilt, ok)

    def _rebuilt(self, ok):
        """메인 스레드. 갱신된 파일로 창을 다시 읽는다."""
        self.building = False
        if not DASHBOARD_HTML.is_file():
            notify("대시보드를 열 수 없습니다",
                   "수집이 한 번도 끝나지 않았습니다" if ok else "수집에 실패했습니다")
            return
        # 이미 떠 있으면 내용만 갈아끼운다. show() 는 창을 앞으로 끌어내므로,
        # 사용자가 그새 다른 창으로 옮겨갔다면 방해가 된다.
        if self.window.is_visible():
            self.window.reload(DASHBOARD_HTML)
        else:
            self.window.show(DASHBOARD_HTML)


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
