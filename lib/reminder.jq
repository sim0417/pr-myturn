# 슬랙 리마인드 문구를 만든다. 대시보드와 메뉴바가 같은 문구를 쓰도록 여기 한 곳에만 둔다.
#
# 입력: { mine: [...pr-status.sh --json 결과], config: {...설정 파일} }
# 출력: { wait: {count, text, html} | null, ready: {...} | null }
#
# text 는 평문 붙여넣기용이고, html 은 슬랙 멘션을 살리기 위한 것이다. 슬랙 입력창은
# 평문 "@이름" 을 멘션으로 바꾸지 않는다. 슬랙이 스스로 복사할 때 쓰는 모양의 링크
# (data-stringify-type="mention" + 사용자 ID + 워크스페이스 주소)를 붙여넣어야 멘션이 된다.
# 워크스페이스 주소가 다르면 멘션이 아니라 일반 링크로 들어간다(2026-10-26 실측).

def short: split("/") | last;

def excluded($ex): . as $r | any($ex[]; . == $r);

# 설정 오타 하나로 수집 전체가 죽지 않도록, 모양이 틀린 값은 없는 것으로 친다.
def strList: if type == "array" then map(select(type == "string")) else [] end;

# 레포는 처음 나온 순서대로 묶는다. group_by 는 이름순으로 다시 정렬해버린다.
def groups: reduce .[] as $p ([];
  (map(.repo) | index($p.repo | short)) as $i
  | if $i == null then . + [{repo: ($p.repo | short), prs: [$p]}]
    else .[$i].prs += [$p] end);

# reminderCc 는 옛 형식(문자열)과 새 형식([{name, slackId}])을 모두 받는다.
def ccPeople:
  if type == "array" then map(if type == "string" then {text: .} elif type == "object" then . else empty end)
  elif type == "string" and . != "" then [{text: .}] else [] end;

def mention($ws):
  if .text then (.text | @html)
  elif (.slackId | type) == "string" and .slackId != "" and $ws != "" then
    ("@" + (.name // "" | tostring)) as $label
    | "<a target=\"_blank\" class=\"c-member_slug c-member_slug--link\""
      + " data-member-id=\"\(.slackId | @html)\" data-member-label=\"\($label | @html)\""
      + " data-stringify-type=\"mention\" data-stringify-id=\"\(.slackId | @html)\""
      + " data-stringify-label=\"\($label | @html)\""
      + " href=\"https://\($ws | @html).slack.com/team/\(.slackId | @html)\""
      + " rel=\"noopener noreferrer\">\($label | @html)</a>"
  else "@" + (.name // "" | tostring) | @html end;

def reminder($prs; $lead; $config):
  ($config.reminderExcludeRepos | strList) as $ex
  | ($config.slackWorkspace | if type == "string" then . else "" end) as $ws
  | ($config.reminderCc | ccPeople) as $cc
  | [ $prs[] | select(.repo | excluded($ex) | not) ] as $list
  | if ($list | length) == 0 then null else
      ($list | groups) as $g
      | { count: ($list | length),
          text: ([$lead, ($g | map("*\(.repo)*\n" + (.prs | map("• \(.title) \(.url)") | join("\n"))) | join("\n\n"))]
                 + (if ($cc | length) > 0 then ["cc " + ($cc | map(.text // ("@" + (.name // "" | tostring))) | join(" "))] else [] end)
                 | join("\n\n")),
          html: ("<meta charset=\"utf-8\">"
                 + ([($lead | @html),
                     ($g | map("<b>\(.repo | @html)</b><br>"
                               + (.prs | map("• \(.title | @html) <a href=\"\(.url | @html)\">\(.url | @html)</a>") | join("<br>")))
                         | join("<br><br>"))]
                    + (if ($cc | length) > 0 then ["cc " + ($cc | map(mention($ws)) | join(" "))] else [] end)
                    | join("<br><br>"))) }
    end;

.config as $config
| (.mine | sort_by(.created)) as $mine
| { wait:  reminder([$mine[] | select(.bucket == "waiting")];
                    "올린 PR 중 아직 리뷰 전인 건들입니다. 확인 한번 부탁 드립니다."; $config),
    ready: reminder([.mine[] | select(.bucket == "merge")];
                    "아래 PR 승인 감사합니다. 머지하겠습니다."; $config) }
