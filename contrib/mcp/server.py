#!/usr/bin/env python3
"""pr-myturn 을 MCP 도구로 노출하는 stdio 서버.

에이전트가 "내 PR 어때?" 를 물으면 도구를 직접 호출한다. 파일 경로를 알려주거나
셸 명령을 조립할 필요가 없다.

의존성을 두지 않는다. MCP 는 stdio 위의 JSON-RPC 2.0 이고, 서버 쪽에서 쓰는 것은
initialize / tools/list / tools/call 세 개뿐이라 표준 라이브러리로 충분하다.
패키지를 하나 더 두면 launchd 로 상시 도는 코드의 공급망이 그만큼 넓어진다.

등록:
    claude mcp add pr-myturn -- python3 <이 파일의 절대경로>
"""
import json
import os
import pathlib
import subprocess
import sys
import time

PROTOCOL_VERSION = "2024-11-05"

REPO = pathlib.Path(__file__).resolve().parents[2]
PR_STATUS = REPO / "bin" / "pr-status.sh"
PR_REPLIES = REPO / "bin" / "pr-review-replies.sh"

CACHE = pathlib.Path(
    os.environ.get("PR_MYTURN_CACHE")
    or pathlib.Path(os.environ.get("XDG_CACHE_HOME", pathlib.Path.home() / ".cache")) / "pr-myturn")
STATUS_JSON = CACHE / "status.json"

# 이보다 오래된 캐시는 믿지 않고 다시 수집한다. 메뉴바 앱이 5분마다 갱신하므로
# 앱이 돌고 있으면 거의 항상 캐시로 답한다.
STALE_AFTER_SEC = 600

ENV = {**os.environ, "PATH": os.pathsep.join(
    ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin",
     os.environ.get("PATH", "")])}

TOOLS = [
    {
        "name": "pr_status",
        "description": (
            "내가 올린 열린 PR 의 현황을 준다. 각 PR 에 bucket(action=내 차례, "
            "merge=승인 완료로 머지 가능, waiting=아직 승인 전)과 reason 이 붙어 있다. "
            "이 분류를 그대로 쓰고 다시 판정하지 마라."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "bucket": {
                    "type": "string",
                    "enum": ["action", "merge", "waiting"],
                    "description": "이 구획만 걸러서 받는다. 생략하면 전부."},
                "refresh": {
                    "type": "boolean",
                    "description": "캐시를 무시하고 GitHub 에서 새로 수집한다. 느리다."},
            },
        },
    },
    {
        "name": "pr_review_replies",
        "description": (
            "내가 리뷰어로 지적한 스레드 중 상대가 답을 달았고 내가 아직 확인하지 "
            "않은 것을 준다. 항상 GitHub 을 호출하므로 몇 초 걸린다."),
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def run(cmd, timeout=120):
    p = subprocess.run(cmd, env=ENV, capture_output=True, text=True,
                       timeout=timeout, check=True)
    return json.loads(p.stdout)


def collect(refresh):
    """캐시가 쓸 만하면 캐시를, 아니면 직접 수집한 결과를 준다."""
    if not refresh and STATUS_JSON.is_file():
        try:
            age = time.time() - STATUS_JSON.stat().st_mtime
            if age < STALE_AFTER_SEC:
                data = json.loads(STATUS_JSON.read_text())
                return data.get("mine", []), {"source": "cache",
                                              "ageSec": round(age),
                                              "generatedAt": data.get("generatedAt")}
        except (OSError, ValueError):
            pass          # 캐시가 깨졌으면 그냥 새로 수집한다
    return run([str(PR_STATUS), "--json"]), {"source": "github"}


def call_tool(name, args):
    if name == "pr_status":
        prs, meta = collect(bool(args.get("refresh")))
        wanted = args.get("bucket")
        if wanted:
            prs = [p for p in prs if p.get("bucket") == wanted]
        return {
            "meta": meta,
            "counts": {b: sum(1 for p in prs if p.get("bucket") == b)
                       for b in ("action", "merge", "waiting")},
            "prs": prs,
        }
    if name == "pr_review_replies":
        return {"replies": run([str(PR_REPLIES), "--json"])}
    raise ValueError(f"알 수 없는 도구: {name}")


def reply(msg_id, result=None, error=None):
    out = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        out["error"] = error
    else:
        out["result"] = result
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def handle(msg):
    method, msg_id = msg.get("method"), msg.get("id")

    # 알림(id 없음)에는 응답하지 않는다. 응답하면 프로토콜 위반이다.
    if msg_id is None:
        return

    if method == "initialize":
        reply(msg_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "pr-myturn", "version": "1.0.0"},
        })
    elif method == "tools/list":
        reply(msg_id, {"tools": TOOLS})
    elif method == "tools/call":
        params = msg.get("params") or {}
        try:
            result = call_tool(params.get("name"), params.get("arguments") or {})
            payload = json.dumps(result, ensure_ascii=False, indent=2)
            reply(msg_id, {"content": [{"type": "text", "text": payload}]})
        except subprocess.CalledProcessError as e:
            detail = (e.stderr or "").strip()[:400] or "수집 명령이 실패했습니다"
            reply(msg_id, {"content": [{"type": "text", "text": detail}], "isError": True})
        except Exception as e:                                  # noqa: BLE001
            reply(msg_id, {"content": [{"type": "text", "text": str(e)[:400]}],
                           "isError": True})
    else:
        reply(msg_id, error={"code": -32601, "message": f"지원하지 않는 메서드: {method}"})


def main():
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw)
        except ValueError:
            continue      # 깨진 줄 하나로 서버를 죽이지 않는다
        handle(msg)


if __name__ == "__main__":
    main()
