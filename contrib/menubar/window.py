"""대시보드를 앱 창에 띄운다.

브라우저 탭이 아니라 창으로 여는 이유는 단순하다. 이건 잠깐 보고 닫는
도구라서, 탭 스무 개 사이에 섞이면 찾는 데 드는 품이 보는 품보다 커진다.

WKWebView 를 쓴다. 메뉴바 앱과 같은 프로세스라 새 런타임을 얹지 않고,
rumps 가 이미 PyObjC 위에 있어 바인딩도 한 겹뿐이다.
"""
import pathlib

import objc
from AppKit import (NSApp, NSBackingStoreBuffered, NSMakeRect, NSObject,
                    NSScreen, NSWindow, NSWindowStyleMaskClosable,
                    NSWindowStyleMaskMiniaturizable, NSWindowStyleMaskResizable,
                    NSWindowStyleMaskTitled, NSWorkspace)
from Foundation import NSURL
from WebKit import WKWebView, WKWebViewConfiguration

STYLE = (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
         | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)

WIDTH, HEIGHT = 1080, 900
MIN_WIDTH, MIN_HEIGHT = 720, 480

# 창 안에서 열려도 되는 것은 대시보드 자신뿐이다. GitHub 링크가 이 창에서
# 열리면 뒤로 가기도 없는 반쪽짜리 브라우저가 되어버린다.
INTERNAL_SCHEMES = ("file",)


class NavigationDelegate(NSObject):
    """대시보드 밖으로 나가는 이동은 기본 브라우저에 넘긴다."""

    def webView_decidePolicyForNavigationAction_decisionHandler_(
            self, _view, action, handler):
        url = action.request().URL()
        scheme = url.scheme() if url else None
        if scheme in INTERNAL_SCHEMES:
            handler(1)          # WKNavigationActionPolicyAllow
            return
        if url:
            NSWorkspace.sharedWorkspace().openURL_(url)
        handler(0)              # WKNavigationActionPolicyCancel


class MessageHandler(NSObject):
    """페이지에서 온 요청을 앱으로 넘긴다.

    지금은 새로고침 하나뿐이다. 서버가 있던 시절에는 브라우저 새로고침이
    곧 재수집이었는데, 서버를 걷어내면서 그 경로가 사라졌다. 창을 열어둔 채
    최신 상태를 보려면 페이지가 앱에게 말을 걸 수 있어야 한다.
    """

    def initWithCallback_(self, callback):
        self = objc.super(MessageHandler, self).init()
        if self is None:
            return None
        self._callback = callback
        return self

    def userContentController_didReceiveScriptMessage_(self, _controller, message):
        if message.body() == "refresh" and self._callback:
            self._callback()


class DashboardWindow:
    """하나만 만들어 두고 열고 닫는다. 매번 새로 만들면 위치를 잊는다."""

    def __init__(self, title="PR 현황 보드", on_refresh=None):
        self._title = title
        self._window = None
        self._webview = None
        self._delegate = NavigationDelegate.alloc().init()
        self._handler = MessageHandler.alloc().initWithCallback_(on_refresh)

    def _build(self):
        screen = NSScreen.mainScreen().visibleFrame()
        rect = NSMakeRect(
            screen.origin.x + (screen.size.width - WIDTH) / 2,
            screen.origin.y + (screen.size.height - HEIGHT) / 2,
            WIDTH, HEIGHT)

        window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, STYLE, NSBackingStoreBuffered, False)
        window.setTitle_(self._title)
        window.setMinSize_((MIN_WIDTH, MIN_HEIGHT))
        window.setReleasedWhenClosed_(False)   # 닫아도 파이썬 쪽에서 계속 들고 있는다

        config = WKWebViewConfiguration.alloc().init()
        # 페이지에서 window.webkit.messageHandlers.prMyturn 으로 부를 수 있게 한다.
        # 브라우저로 같은 파일을 열면 이 객체가 없고, 페이지는 그때 새로고침
        # 버튼을 감춘다. 죽은 버튼을 보여주지 않기 위해서다.
        config.userContentController().addScriptMessageHandler_name_(
            self._handler, "prMyturn")

        webview = WKWebView.alloc().initWithFrame_configuration_(
            window.contentView().bounds(), config)
        webview.setAutoresizingMask_(2 | 16)   # 너비·높이 모두 따라 늘어난다
        webview.setNavigationDelegate_(self._delegate)
        window.contentView().addSubview_(webview)

        self._window, self._webview = window, webview

    def show(self, html_path):
        """파일을 읽어 창에 띄우고 앞으로 가져온다. 이미 떠 있으면 다시 읽는다."""
        path = pathlib.Path(html_path)
        if not path.is_file():
            raise FileNotFoundError(path)

        if self._window is None:
            self._build()

        url = NSURL.fileURLWithPath_(str(path))
        # file:// 문서가 같은 디렉터리를 읽을 수 있게 접근 범위를 함께 준다.
        self._webview.loadFileURL_allowingReadAccessToURL_(
            url, NSURL.fileURLWithPath_(str(path.parent)))

        # 메뉴바 전용(accessory) 앱이라 그냥 두면 창이 뒤로 숨는다.
        NSApp.activateIgnoringOtherApps_(True)
        self._window.makeKeyAndOrderFront_(None)

    def is_visible(self):
        """창이 화면에 있나. 떠 있을 때만 자동으로 다시 읽기 위해 쓴다."""
        return self._window is not None and bool(self._window.isVisible())

    def reload(self, html_path):
        """이미 떠 있는 창의 내용만 갈아끼운다. 앞으로 끌어내지는 않는다.

        show() 와 달리 포커스를 뺏지 않는다. 5분마다 자동 갱신할 때 창이
        다른 작업 위로 튀어나오면 성가시기만 하다.
        """
        if not self.is_visible():
            return
        path = pathlib.Path(html_path)
        if path.is_file():
            self._webview.loadFileURL_allowingReadAccessToURL_(
                NSURL.fileURLWithPath_(str(path)),
                NSURL.fileURLWithPath_(str(path.parent)))

    def close(self):
        if self._window is not None:
            self._window.orderOut_(None)
