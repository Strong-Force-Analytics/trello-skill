#!/usr/bin/env bash
# Trello raw-API helper. Source it:  source ~/.claude/skills/trello/trello.sh
# Creds live in ~/.claude/.trello.env (never committed).
set -euo pipefail

ENV_FILE="${HOME}/.claude/.trello.env"
[ -f "$ENV_FILE" ] || { echo "MISSING $ENV_FILE — fill creds first" >&2; return 1 2>/dev/null || exit 1; }
set -a; source "$ENV_FILE"; set +a
case "${TRELLO_KEY:-}" in ""|PUT_YOUR_KEY_HERE) echo "TRELLO_KEY not set in $ENV_FILE" >&2; return 1 2>/dev/null || exit 1;; esac

AUTH="key=${TRELLO_KEY}&token=${TRELLO_TOKEN}"
# Header auth — REQUIRED for downloading attachment bytes (query params don't authorize the file fetch).
HDR="Authorization: OAuth oauth_consumer_key=\"${TRELLO_KEY}\", oauth_token=\"${TRELLO_TOKEN}\""

# --- reads (fields= trims response = token-lean) ---
tr_me()      { curl -s "https://api.trello.com/1/members/me?fields=username,fullName&$AUTH"; }
tr_boards()  { curl -s "https://api.trello.com/1/members/me/boards?fields=name,url&$AUTH"; }
tr_lists()   { curl -s "https://api.trello.com/1/boards/$1/lists?fields=name&$AUTH"; }              # tr_lists BOARD_ID
tr_cards()   { curl -s "https://api.trello.com/1/lists/$1/cards?fields=name,desc&$AUTH"; }          # tr_cards LIST_ID
tr_card()    { curl -s "https://api.trello.com/1/cards/$1?fields=${2:-name,desc,shortUrl,idList}&$AUTH"; } # tr_card SHORTLINK_or_ID [fields]
tr_atts()    { curl -s "https://api.trello.com/1/cards/$1/attachments?fields=name,url,bytes,mimeType&$AUTH"; } # tr_atts CARD_ID
tr_comments(){ curl -s "https://api.trello.com/1/cards/$1/actions?filter=commentCard&fields=date&limit=${2:-50}&$AUTH"; } # tr_comments CARD_ID [limit]

# --- attachment download (bytes, auth header) ---
# tr_dl CARD_ID ATT_ID FILENAME OUTPATH
tr_dl()      { curl -s -L -o "$4" -H "$HDR" "https://api.trello.com/1/cards/$1/attachments/$2/download/$3"; echo "saved -> $4"; }

# --- writes ---
# Any non-ASCII char (em-dash, curly quotes, accents, emoji) passed as a literal shell
# arg on Windows gets mangled by the time curl sees it (cp1252 byte, not UTF-8) and is
# stored corrupted. Fix is structural, not "remember to avoid em-dash": write the text
# to a UTF-8 file with the Write tool first, then pass it here — curl reads file bytes
# directly and never round-trips through argv/shell-string interpolation.
# This is ENFORCED, not just documented: every inline (non-file) text arg is passed
# through _tr_guard, which HARD-ERRORS on any non-ASCII byte instead of storing garbage.
# Full rule set: the "Write mechanics" section of SKILL.md (single source of truth).
_tr_guard() {
  if LC_ALL=C printf '%s' "${1-}" | LC_ALL=C grep -q '[^[:print:][:space:]]'; then
    echo "ERROR: non-ASCII inline arg -> write the text to a UTF-8 file and pass the file path instead (see 'Write mechanics' in SKILL.md)." >&2
    return 3
  fi
}
# tr_comment CARD_ID "short pure-ASCII text"   OR   tr_comment CARD_ID /path/to/text.txt
# File is read via `cat` (not @file) — avoids MSYS curl exit-26 on Windows paths.
tr_comment() {
  local text; if [ -f "$2" ]; then text=$(cat "$2"); else _tr_guard "$2" || return 3; text="$2"; fi
  curl -s -X POST "https://api.trello.com/1/cards/$1/actions/comments?$AUTH" --data-urlencode "text=$text"
}
# Edit an existing comment. ACTION_ID is the .id returned by tr_comment (NOT the card id).
# Same file-safe rule as tr_comment: pass a FILE path for anything non-ASCII.
# tr_comment_update ACTION_ID "short pure-ASCII text"   OR   tr_comment_update ACTION_ID /path/to/text.txt
tr_comment_update() {
  local text; if [ -f "$2" ]; then text=$(cat "$2"); else _tr_guard "$2" || return 3; text="$2"; fi
  curl -s -X PUT "https://api.trello.com/1/actions/$1?$AUTH" --data-urlencode "text=$text"
}
tr_upload()  { curl -s -X POST "https://api.trello.com/1/cards/$1/attachments?$AUTH" -F "file=@$2" -F "setCover=false"; }   # tr_upload CARD_ID FILEPATH  (setCover=false — Trello defaults images to cover otherwise)

# Update card name/desc — same file-safe rule as tr_comment. Pass FILE paths, not literal text.
# tr_card_update CARD_ID name=/path/to/name.txt desc=/path/to/desc.txt   (either or both)
# File content read via `cat` — avoids MSYS curl exit-26 on Windows paths.
tr_card_update() {
  local card="$1"; shift
  local args=()
  for kv in "$@"; do
    local key="${kv%%=*}" val="${kv#*=}"
    local content; if [ -f "$val" ]; then content=$(cat "$val"); else _tr_guard "$val" || return 3; content="$val"; fi
    args+=(--data-urlencode "$key=$content")
  done
  curl -s -X PUT "https://api.trello.com/1/cards/$card?$AUTH" "${args[@]}"
}

# --- card lifecycle (create / checklist / move) ---
# Text args are FILE-SAFE: pass a FILE PATH for anything non-ASCII (em-dash,
# emoji, accents). A literal non-ASCII argv is mangled on Windows (cp1252 -> wrong
# %XX, stored corrupted) — same trap as tr_comment. Pure-ASCII literals are fine.
# tr_card_create LIST_ID NAME_or_FILE [DESC_FILE]  -> card JSON (capture .id/.shortUrl)
tr_card_create() {
  local n d=(); if [ -f "$2" ]; then n=(--data-urlencode "name@$2"); else _tr_guard "$2" || return 3; n=(--data-urlencode "name=$2"); fi
  [ -n "${3:-}" ] && d=(--data-urlencode "desc=$(cat "$3")")
  curl -s -X POST "https://api.trello.com/1/cards?$AUTH" --data-urlencode "idList=$1" "${n[@]}" "${d[@]}"
}
# tr_checklist_add CARD_ID NAME  -> checklist JSON (capture .id)
tr_checklist_add() { _tr_guard "$2" || return 3; curl -s -X POST "https://api.trello.com/1/cards/$1/checklists?$AUTH" --data-urlencode "name=$2"; }
# tr_checkitem_add CHECKLIST_ID NAME_or_FILE  -> checkItem JSON (appended at bottom)
tr_checkitem_add() {
  local n; if [ -f "$2" ]; then n=(--data-urlencode "name@$2"); else _tr_guard "$2" || return 3; n=(--data-urlencode "name=$2"); fi
  curl -s -X POST "https://api.trello.com/1/checklists/$1/checkItems?$AUTH" --data-urlencode "pos=bottom" "${n[@]}"
}
# tr_card_checklists CARD_ID  -> checklists with id,name (use .id as CHECKLIST_ID for tr_checkitems)
tr_card_checklists() { curl -s "https://api.trello.com/1/cards/$1/checklists?fields=id,name&$AUTH"; }
# tr_checkitems CHECKLIST_ID  -> items with id,name,state
# NOTE: takes CHECKLIST_ID (from tr_card_checklists), NOT card ID -- unlike tr_checkitem_set below.
tr_checkitems() { curl -s "https://api.trello.com/1/checklists/$1/checkItems?fields=name,state&$AUTH"; }
# tr_checkitem_set CARD_ID CHECKITEM_ID complete|incomplete [NAME_or_FILE]  (state=complete renders the ✅)
tr_checkitem_set() {
  local args=(--data-urlencode "state=$3")
  if [ -n "${4:-}" ]; then if [ -f "$4" ]; then args+=(--data-urlencode "name@$4"); else _tr_guard "$4" || return 3; args+=(--data-urlencode "name=$4"); fi; fi
  curl -s -X PUT "https://api.trello.com/1/cards/$1/checkItem/$2?$AUTH" "${args[@]}"
}
# tr_card_move CARD_ID LIST_ID  (advance card lifecycle: In Progress -> Review -> Done)
tr_card_move() { curl -s -X PUT "https://api.trello.com/1/cards/$1?$AUTH" --data-urlencode "idList=$2"; }

# raw passthrough for anything not wrapped:  tr_get "/1/cards/ID?fields=name"
tr_get()     { curl -s "https://api.trello.com$1$([[ "$1" == *\?* ]] && echo "&" || echo "?")$AUTH"; }

# cards assigned to ME — tr_mine LIST_ID   (uses TRELLO_MEMBER_ID)
tr_mine()    { curl -s "https://api.trello.com/1/lists/$1/cards?fields=name,idMembers,url&$AUTH" \
                 | python -c "import sys,json,os; me=os.environ['TRELLO_MEMBER_ID']; [print('-',c['name'],'|',c['url']) for c in json.load(sys.stdin) if me in c.get('idMembers',[])] or print('(none)')"; }
# cards assigned to ME across a whole board — tr_mine_board BOARD_ID
tr_mine_board(){ curl -s "https://api.trello.com/1/boards/$1/cards?fields=name,idMembers,url&$AUTH" \
                 | python -c "import sys,json,os; me=os.environ['TRELLO_MEMBER_ID']; [print('-',c['name'],'|',c['url']) for c in json.load(sys.stdin) if me in c.get('idMembers',[])] or print('(none)')"; }
