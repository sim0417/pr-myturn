# pr-myturn

내가 올린 PR과 내가 리뷰한 PR 중 **지금 내 차례인 것**만 골라 보여주는 로컬 대시보드입니다.
GitHub 알림함은 읽은 것과 안 읽은 것으로만 나뉘지만, 실제로 알고 싶은 건 "누가 나를 기다리고 있나"입니다.

`gh` CLI 위에서 도는 셸 스크립트 세 개와 정적 HTML 하나가 전부입니다. 서버에 데이터를 보내지 않고,
토큰을 따로 저장하지도 않습니다.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/pr-dashboard-dark.png">
  <img alt="PR 현황 보드 — 리뷰 대기, 응답 필요, 머지 대기, 내 리뷰 답글 네 구획으로 나뉜 대시보드" src="docs/pr-dashboard-light.png">
</picture>

<sub>스크린샷은 가짜 데이터입니다. `docs/demo.html` 을 열면 같은 화면을 직접 볼 수 있습니다.</sub>

## 무엇을 보여주나

| 구획 | 기준 |
|---|---|
| 리뷰 대기 | 내 PR 중 승인 0건 |
| 응답 필요 | 상대 코멘트·미해결 스레드에 내 답이 없는 것 |
| 머지 대기 | 승인받고 아직 머지하지 않은 것 |
| 내 리뷰 답글 | 내가 남긴 리뷰에 상대가 답했고 내가 아직 안 본 것 |

**"응답 필요"의 판정이 이 도구의 핵심입니다.** 단순히 "마지막 코멘트가 내 것이 아닌가"로 판정하면,
승인 버튼과 별개로 "LGTM" 코멘트를 남기는 리뷰어 때문에 승인된 PR이 전부 응답 필요로 올라옵니다.
그래서 같은 사람의 승인이 코멘트와 시간적으로 붙어 있으면(기본 10분) 승인의 일부로 봅니다.
승인하고 한참 뒤에 달린 코멘트는 진짜 질문일 수 있으므로 그대로 남깁니다.

## 요구 사항

- [`gh`](https://cli.github.com) — 로그인되어 있어야 합니다 (`gh auth login`)
- `jq` 1.6+
- `python3`
- bash

## 설치

```sh
git clone https://github.com/<you>/pr-myturn.git
cd pr-myturn
./bin/pr-dashboard.sh
```

브라우저가 열립니다. 새로고침할 때마다 다시 수집합니다.

```
pr-dashboard.sh            서버를 띄우고 브라우저로 열기
pr-dashboard.sh --full     머지된 PR 답글까지 강제 재수집
pr-dashboard.sh --file     서버 없이 정적 파일로 열기
pr-dashboard.sh --stop     백그라운드 서버 종료
```

스크립트는 개별로도 씁니다. `--json` 을 붙이면 가공용 JSON이 나옵니다.

```sh
./bin/pr-status.sh                  # 내 PR 3분류
./bin/pr-review-replies.sh --json   # 내 리뷰에 달린 미확인 답글
```

## 설정

설정은 **선택**입니다. 없으면 GitHub 로그인을 그대로 표시하고 기본값으로 돕니다.

```sh
mkdir -p ~/.config/pr-dashboard
cp config.example.json ~/.config/pr-dashboard/config.json
chmod 600 ~/.config/pr-dashboard/config.json
```

`chmod` 를 빼먹지 마세요. macOS 홈 디렉터리는 그룹(`staff`)에 읽기 권한이 있어서,
기본 권한으로 두면 같은 머신의 다른 계정이 팀원 실명 매핑을 읽을 수 있습니다.

| 키 | 뜻 | 기본값 |
|---|---|---|
| `displayName` | 대시보드 제목에 붙일 이름 | 없음 |
| `names` | GitHub 로그인 → 표시 이름 매핑 | 없음(로그인 그대로) |
| `excludeOwners` | 집계에서 뺄 소유자 (개인 레포 등) | `[]` |
| `bots` | 코멘트를 무시할 봇 계정 | github-actions, dependabot, codecov, renovate |
| `reminderCc` | 슬랙 리마인드 문구 끝에 붙일 멘션 | 없음 |
| `closedWithinDays` | 머지된 PR을 며칠까지 거슬러 볼지 | 30 |
| `approvalWindowSec` | 승인과 한 묶음으로 볼 코멘트 시간차 | 600 |

`names` 는 팀원 실명을 담게 되므로 **설정 파일에만 두고 커밋하지 마세요.** 이 레포의
`.gitignore` 가 `config.json` 을 막아두었지만, 다른 위치에 두는 편이 안전합니다.

`PR_DASHBOARD_CONFIG` 로 경로를 직접 지정할 수도 있습니다.

## 메뉴바 앱 (선택)

대시보드의 한계는 **내가 열어봐야 안다**는 점입니다. `contrib/menubar` 는 지금 내 차례인
건수를 메뉴바에 상시로 띄웁니다.

```sh
./contrib/menubar/install.sh
```

`gh`, `jq`, `python3` 만 있으면 됩니다. 전용 가상환경에 [rumps](https://github.com/jaredks/rumps)
를 받고 launchd 에 등록해 로그인할 때마다 뜹니다.

```
PR 6          ← 답변 필요 + 머지 가능 건수
  답변 필요 1건
      acme-web#405  Fix: 장바구니 수량 변경 시 합계가…
  머지 가능 5건
      ...
  대시보드 열기 / 지금 새로고침
```

- 배지는 **답변 필요 + 머지 가능**입니다. 리뷰 대기는 상대 차례이므로 빼고 메뉴에서만 보여줍니다.
- 항목을 누르면 그 PR 이 열립니다.
- 답변 필요가 **늘어난 순간에만** 알림을 띄웁니다. 같은 건으로 반복해 알리지 않습니다.
- 기본 5분 간격입니다. `config.json` 의 `menubarPollSec` 으로 바꿉니다.
- 수집은 `bin/pr-status.sh` 를 그대로 호출하므로 판정이 대시보드와 어긋나지 않습니다.

제거는 `./contrib/menubar/install.sh --uninstall` 입니다.

터미널에서 `python3 app.py` 로 직접 실행하면 프로세스는 뜨지만 **메뉴바에는 나타나지 않습니다.**
macOS 는 GUI 세션에 속한 프로세스만 상태 아이템을 그리기 때문이며, `install.sh` 가 launchd 에
등록하는 이유입니다. 첫 알림에서 macOS 가 권한을 물을 수 있습니다.

## 데이터와 보안

- 수집한 데이터는 `~/.cache/pr-dashboard/` 아래에만 남습니다. 외부로 나가지 않습니다.
  캐시 디렉터리는 `700`, 그 안의 파일은 `600` 으로 만듭니다. PR 제목과 코멘트 원문이
  담기는 곳이라 같은 머신의 다른 계정에게도 보이지 않아야 합니다.
- 메뉴바 앱의 의존성은 `contrib/menubar/requirements.txt` 에 버전을 고정했습니다.
  launchd 로 상시 실행되는 코드라 매번 최신을 받아오지 않습니다.
- 인증은 전적으로 `gh` CLI에 맡깁니다. 이 저장소의 코드는 토큰을 읽거나 저장하지 않습니다.
- 로컬 서버는 `127.0.0.1` 에만 바인딩하고 `Host` 헤더를 검사합니다. 악성 페이지가 DNS
  rebinding으로 대시보드 내용을 읽어가는 경로를 막기 위한 것입니다.
- PR 제목과 코멘트는 GitHub에서 온 신뢰할 수 없는 입력으로 다룹니다. DOM은 전부
  `textContent` 로 만들고, 데이터를 `<script>` 안에 넣을 때 `<` 를 `<` 로 이스케이프해
  스크립트 블록 탈출을 막습니다.

캐시에는 회사 PR 제목과 코멘트가 그대로 들어갑니다. **스크린샷을 공유할 때 주의하세요.**

## 한계

- GitHub search API가 1000건까지만 반환합니다. 그 이상이면 `closedWithinDays` 를 줄이세요.
- 열린 PR 50건까지 봅니다.
- `stat`, `open` 사용 때문에 macOS에서 주로 검증했습니다. 리눅스는 `open` 을 `xdg-open` 으로
  바꿔야 합니다.

## 라이선스

MIT
