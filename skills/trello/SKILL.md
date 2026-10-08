---
name: trello
description: Access the user's Trello over the raw REST API — list boards/lists/cards, read/download attachments, post comments, upload files to cards. Use when the user mentions Trello, a board/card/list, or asks to fetch/comment/upload Trello attachments.
---

# Trello (raw-API skill)

Helper for the user's Trello via curl. Token-lean (responses trimmed with `fields=`), local-file upload + attachment **byte download** (the gap most MCP servers miss).

## Setup (once)
Creds live in `~/.claude/.trello.env` — three variables:
- `TRELLO_KEY`, `TRELLO_TOKEN` — get both at https://trello.com/power-ups/admin/new (see the repo README for the full walkthrough with screenshots).
- `TRELLO_MEMBER_ID` — your member ID (used by `tr_mine` / `tr_mine_board`). After `TRELLO_KEY`/`TRELLO_TOKEN` are set, run `source "$(command -v trello.sh 2>/dev/null || echo "${HOME}/.claude/skills/trello/trello.sh")" && tr_get "/1/members/me?fields=id,username"` and paste the `id` back into the env file.

Copy `.trello.env.example` from the repo to `~/.claude/.trello.env` and fill it in. If placeholders are unfilled, tell the user to fill that file. **Never print the token.**

## Usage
Source the helper, then call functions. Run via the Bash tool:
```bash
source "$(command -v trello.sh 2>/dev/null || echo "${HOME}/.claude/skills/trello/trello.sh")"
tr_me                         # verify creds -> username
tr_boards                     # boards + IDs
tr_lists  BOARD_ID            # lists on a board
tr_cards  LIST_ID             # cards in a list
tr_card   SHORTLINK [fields]  # ONE card by shortlink/ID (default: name,desc,shortUrl,idList)
tr_atts   CARD_ID             # attachments (id, name, bytes, mime)
tr_dl     CARD_ID ATT_ID FILENAME OUTPATH   # download bytes (auth header)
tr_comment CARD_ID "text"|FILE      # post comment -> returns action JSON (capture .id). Use a FILE path (Write tool, UTF-8) for anything non-trivial/non-ASCII.
tr_comment_update ACTION_ID "text"|FILE  # edit existing comment (ACTION_ID from tr_comment response)
tr_card_update CARD_ID name=FILE [desc=FILE]   # update title/description -> same FILE-path rule
tr_upload  CARD_ID FILEPATH   # attach local file to card
tr_get    "/1/..."            # raw passthrough for unwrapped endpoints
tr_mine        LIST_ID        # cards in a list assigned to me (uses TRELLO_MEMBER_ID)
tr_mine_board  BOARD_ID       # cards on a whole board assigned to me
# --- card lifecycle (create / checklist / move) — text args FILE-SAFE like tr_comment ---
tr_card_create LIST_ID NAME|FILE [DESC_FILE]   # create card -> JSON (capture .id, .shortUrl)
tr_checklist_add CARD_ID NAME                  # add checklist -> JSON (capture .id)
tr_checkitem_add CHECKLIST_ID NAME|FILE        # add item at bottom
tr_card_checklists CARD_ID                     # list checklists with id,name (use .id as CHECKLIST_ID below)
tr_checkitems CHECKLIST_ID                     # list items (id, name, state) — takes CHECKLIST_ID, not card ID
tr_checkitem_set CARD_ID ITEM_ID complete|incomplete [NAME|FILE]  # tick / untick
tr_card_move CARD_ID LIST_ID                   # advance lifecycle (In Progress->Review->Done)
```
Each Bash call is a fresh shell — `source` the helper every call.

Note: Trello has **no comment-level attachments**. "Upload at a comment" = `tr_comment` + `tr_upload` (card-level); they sit together in the card feed.

**An upload must never become the card cover.** Set 2026-09-08. An image attached for any
reason — embedded in a description, sitting under a comment, or a plain attachment — stays a
plain attachment. Set a cover only when the user asks for one in so many words. `tr_upload`
sends `setCover=false` for exactly this; keep it, and never hand-roll an upload without it.
Verify after every image upload:

```bash
tr_get "/1/cards/CARD_ID?fields=idAttachmentCover"    # expect null
```

If a cover did land, clearing it per-card does not reliably hold while the board's
`cardCovers` pref is `true` — see Lessons. Switching that pref off is board-wide, so confirm
with the user before touching it.

## Write mechanics (non-negotiable)
Single source of truth for every card write. Other skills and commands should point here
instead of copying these. Three rules, all of which fail SILENTLY:

1. **Non-ASCII -> file, ALWAYS.** Any em-dash, curly quote, accent, arrow, or emoji passed as
   an inline literal is corrupted to a `%XX` byte on Windows (cp1252, not UTF-8) *before curl
   sees it*. Write the text to a UTF-8 file with the `Write` tool and pass the **file path**;
   the helper streams file bytes and never round-trips through argv. Plain ASCII `-` inline is
   fine; `—` is not. **This is now ENFORCED, not just advised:** every inline (non-file) text
   arg runs through `_tr_guard`, which HARD-ERRORS (rc 3) on any non-ASCII byte rather than
   storing garbage — so a forgotten em-dash fails loudly instead of corrupting silently.
2. **One Trello write per Bash call.** Batched writes (a loop of adds / ticks / any POST or PUT
   in one invocation) silently drop all but the first — a burst-outbound throttle, unaffected by
   `sleep`. Issue each write as its own Bash tool call (GET reads batch fine).
3. **Verify what landed.** After writing, re-read (`tr_card CARD_ID`, or
   `tr_get "/1/actions/ID?fields=data"` — comment text is at `.data.text`) and scan for stray
   `%XX` before declaring done. **Verify in PowerShell, not python-through-bash** — piping
   Trello JSON into python on Windows drops emoji to a zero count and reads as "the emoji
   never landed" when they landed fine. `Invoke-RestMethod` + `-match` on the line shows the
   truth.
4. **Emoji/non-ASCII in a description or checkItem -> PowerShell, not `tr_card_update`.**
   The `desc=FILE` path reads the file with `cat` into a bash variable and passes it through
   `--data-urlencode`, i.e. still argv — fine for ASCII, mangles emoji. Use:
   ```powershell
   $uri  = "https://api.trello.com/1/cards/$sl`?key=$key&token=$token"
   $body = "desc=$([uri]::EscapeDataString((Get-Content $file -Raw)))"
   Invoke-RestMethod -Uri $uri -Method Put -Body $body -ContentType "application/x-www-form-urlencoded"
   ```

## Status vocabulary (team convention)

> **Scope, set 2026-08-24.** These marks belong to **legacy roadmap-style descriptions** — a body
> that is a list of phases carrying their own state. They are **not** used on the standard card in
> "Card description style" below, where progress lives in the checklist's progress bar and nowhere
> else. Never add marks to a description that has a Steps checklist.

In such descriptions, mark state with these and nothing else:

| Mark | Means |
|---|---|
| ✅ | done |
| 🟢 | in progress / ongoing |
| ⬜ | not started / left |

Put the mark on the parent line *and* on each sub-item, and open the roadmap with a
`Legend: ✅ done · 🟢 in progress · ⬜ not started` line. This is the team's convention —
do not substitute `DONE` / `PARTLY` / `NOT STARTED` text, and do not invent other symbols.

## Card description style (the standard card)
Set 2026-08-24, after two cards came out too long. A card has one job: say what the problem is and
what we are going to do about it. It is not a report.

- **Write in first person, as the team.** "We placed it by hand", "we need a timer". Never write
  as the assistant describing someone else's project.
- **Three parts, in this order: the scenario, the solution, then `Steps to work on`.**
  - **Scenario** — what changed, where we are, what is wrong. A few bullets.
  - **Solution** — the approach we have settled on. What we are going to do, not how far along it
    is. Progress and outcomes go in a **comment posted after the work is done** — never written
    ahead of the action.
  - **Steps** — the work broken down. See the formatting rule below.
- **Short. Few words per line.** Bullets, nested one level where a point needs detail. No
  paragraphs, no narrative, no "where we got to" essays. If a line reads like a sentence from a
  report, cut it down.
- **`Steps to work on` formatting.** Numbered steps, each with its sub-points nested underneath as
  short bullets, **indented exactly 3 spaces** to match the width of the `1. ` marker. Two
  spaces breaks the nesting and Trello renders every step as `1.` — see Lessons. No blank
  lines between the numbered items. This is where the detail belongs.
- **No status marks, no emoji, no bold.** Keep every line the same weight.
- **Plainer than a comment.** A comment keeps the team's own domain vocabulary; a description is
  read by whoever picks the card up cold, so lean plain. No file paths, no code identifiers — say
  "the start-up checklist", not the filename. Keep a domain word only where there is no plain
  equivalent; do not strip one out and leave a sentence that says nothing.

**The checklist mirrors the steps, names only.** One item per numbered step, worded the same, with
**no sub-steps and no verifier lines** — it exists for the progress bar and for ticking, which is a
visual signal, not documentation. Detail already lives in the description.

**Do not add a "Do not decide" checklist.** Open questions belong in conversation or in the repo's
own open-items, not on the card.

## Comment style (team-facing recaps)

**Read the last 3-4 comments on the card before drafting:**

```bash
tr_get "/1/cards/CARD_ID/actions?filter=commentCard&limit=4&fields=data"
```

The board has a house voice; match it rather than importing one. **This step is not
optional** — skipping it is how a comment ends up reading as generated.

The default shape, taken from what the team actually writes:

- **Topic heading, then bullets.** No summary line, no bold, no emoji.
- **First person, as the team.** "we nearly took a free account", not "the team identified
  a risk".
- **Fragments are correct.** Short, lowercase starts are fine. A full grammatical sentence
  on every bullet is the clearest tell of generated text.
- **Keep domain vocabulary, cut implementation names.** 0DTE, drawdown, Express, spreads,
  ORB — the team uses these daily and removing them destroys the meaning. What does not
  belong: file paths, function names, endpoints. Say "it was calling something that doesn't
  exist", not the function name.
- **Spell out units** ("240 euro", not the euro sign). No decorative symbols in comments —
  the ✅ / 🟢 / ⬜ status marks are for descriptions and checklists only.
- **Never pass comment/title/description text as a literal shell argument** — write it to a
  UTF-8 file and pass the path. See **"Write mechanics (non-negotiable)"** above (now enforced
  by `_tr_guard`); don't restate the rule here.
- **Confirm the draft with the user before posting.**

A shipped-feature announcement can instead use: title + one-line summary / "What is new,
live now:" / "\<Owner\> team need to work on these:". **That is one option for one
situation, not the default.**

## Safety
- Destructive ops (delete/archive) are NOT wrapped — for those, confirm with the user, then use `tr_get` / explicit curl.
- Token = full account access. Keep it in `.trello.env` only; never echo it.

## Lessons
- `tr_get` takes a **full API path**, NOT a bare card ID. `tr_get AbCd1234` builds a broken
  URL (`api.trello.comAbCd1234`) → empty body. Either `tr_get "/1/cards/AbCd1234?fields=name"`
  or use the wrapped `tr_card AbCd1234`.
- Single-card lookup by shortlink: `tr_card SHORTLINK` (the 8-char code in `trello.com/c/XXXX`).
- Attachment byte download needs the `Authorization: OAuth ...` **header**; `key/token` query params alone return 401 for the file. (`tr_dl` handles it.)
- Comment permalink: `tr_comment` returns the action JSON — build the shareable URL from
  `.data.card.shortLink` + the action `.id`:
  `https://trello.com/c/<shortLink>#comment-<actionId>`
  (e.g. id `6a3d…` on card `AbCd1234` → https://trello.com/c/AbCd1234#comment-6a3d…).
  The short `/c/<shortLink>` path redirects to the full card; the `#comment-<id>` anchor jumps to it.
- Non-ASCII text (em-dash, curly quotes, accents) passed as a literal arg to `tr_comment`
  gets mangled on Windows (cp1252 byte → wrong `%XX` escape, stored corrupted, e.g. an
  em-dash becomes literal `%97`). Found it twice: once in a posted comment, once baked
  into a card's title/desc. Fixed structurally — `tr_comment` and `tr_card_update` now
  accept a **file path** (write the text with the `Write` tool first) and stream it via
  `--data-urlencode text@FILE`, which never touches argv. Always use the file form unless
  the text is short and pure ASCII.
- Image uploads auto-becoming the card cover is a **board-level** setting
  (`boards/{id}/prefs.cardCovers`), not a per-upload thing. Passing `setCover=false` on
  the `tr_upload` POST does NOT reliably stop it — confirmed by testing: even after
  manually clearing `idAttachmentCover=null`, the cover silently reappeared on its own
  with zero new API calls, purely because the board pref was still `true`. `tr_upload`
  now sends `setCover=false` as a harmless extra, but the actual fix (when the user wants
  it) is `curl -X PUT ".../boards/BOARD_ID/prefs/cardCovers?value=false&$AUTH"` — confirm
  with the user first, it's board-wide, not scoped to one card.
  **Update 2026-09-08:** `setCover=false` did hold on a fresh upload to Data Projects
  (`idAttachmentCover` still `null` on read-back) with the board's `cardCovers` pref left at
  `true`. So the flag is not useless — it is just not a guarantee, since the earlier failure
  was a cover reappearing later rather than at upload time. Keep sending it, and keep
  verifying on read-back; only reach for the board pref if a cover actually appears.
- A comment action's text is nested at `.data.text`, not top-level `.text`. Verifying a
  posted comment with `tr_get "/1/actions/ID?fields=text"` returns no `text` key (KeyError
  if you index it). Use `fields=data` and read `.data.text`.
- The Windows non-ASCII argv trap bites **checkItem names too**, not just comments/desc.
  Creating checklist items with em-dashes via `--data-urlencode "name=$1"` stored them as
  `%97`/`%2F`/`%28` (double-mangled). Fixed structurally: added `tr_card_create`,
  `tr_checklist_add`, `tr_checkitem_add`, `tr_checkitem_set` — all **file-safe** (pass a
  FILE path for any non-ASCII, `name@FILE`). Pure-ASCII literals (plain `-`, not `—`) are
  fine inline. There was no card-create/checklist helper before; hand-rolled curl each time.
- **MSYS curl `@file` fails on Windows paths — use PowerShell for multi-card UTF-8 writes.**
  `--data-urlencode "name@/c/Users/..."` exits 26 (can't read file) because MSYS curl
  doesn't resolve `/c/` Windows paths for file reads. Inline `--data-urlencode "name=..."` 
  still mangles non-ASCII through argv (cp1252). Fix: use PowerShell `Invoke-RestMethod`
  with key+token in the query string and `[uri]::EscapeDataString()` for the body value:
  ```powershell
  $uri  = "https://api.trello.com/1/cards/${sl}?key=${key}&token=${token}"
  $body = "name=$([uri]::EscapeDataString($name))"
  Invoke-RestMethod -Uri $uri -Method Put -Body $body -ContentType "application/x-www-form-urlencoded"
  ```
  PowerShell strings are UTF-16 internally but `Invoke-RestMethod` encodes the body as
  UTF-8 bytes — no argv mangling. Multiple cards can loop in one PowerShell call (no
  burst-throttle issue for PUTs from PS, unlike Bash).
- **`tr_comment`/`tr_card_update` file paths now use `cat` internally, not curl `@file`.** MSYS curl on Windows exits 26 when given a file path via `--data-urlencode "key@/path"` (can't resolve MSYS paths for file reads). Fixed in trello.sh: both functions now read content with `cat "$file"` into a bash variable and pass `--data-urlencode "key=$var"`. Pure ASCII content goes through fine. Non-ASCII still needs the PowerShell workaround (variable mangling through argv on Windows cp1252).
- **`tr_card_create` DESC_FILE had the same `@file` bug** (curl exit 26, card not created). Fixed 2026-10-01: it now reads the desc with `cat` like `tr_comment`. ASCII only; emoji in a desc still need the PowerShell path.
- **`tr_card_checklists CARD_ID` added.** Previously had to hand-roll curl to get checklist IDs from a card. Use it to get CHECKLIST_ID before calling `tr_checkitems`. Asymmetry to remember: `tr_checkitems` takes CHECKLIST_ID; `tr_checkitem_set` takes CARD_ID.
- **Batched writes fail — do ONE write per Bash invocation.** Ticking many checkItems
  (or any loop of PUT/POST) in a single `source trello.sh && for ... tr_checkitem_set ...`
  invocation: only the FIRST write lands; the rest return an empty body / `HTTP 000`,
  regardless of `sleep` spacing OR `dangerouslyDisableSandbox`. GET reads batch fine; it
  is specifically multiple *writes* from one shell process (burst-outbound throttle).
  Reliable fix: one write per Bash tool call (issue them as separate/parallel single-tick
  calls). Hit 2026-07-11 ticking a 6-item checklist — each item needed its own call.
- **Emoji in a description survive `Invoke-RestMethod`, and the check that says they didn't
  is usually wrong.** 2026-08-12: pushed a roadmap description carrying ✅ / 🟢 / ⬜ via the
  PowerShell path, then verified by piping `tr_card AbCd1234 desc` into python — it reported
  zero of each and no `%XX`, which reads as "silently stripped". Re-reading the same field
  with `Invoke-RestMethod` showed all three marks intact. The loss was in python's stdout
  encoding under MSYS, not in Trello. Verify non-ASCII writes from PowerShell.
- **Ordered/nested list rendering — SOLVED 2026-08-31. Indent sub-bullets by exactly 3
  spaces.** A `1. ` marker is three characters wide, so a nested bullet has to start at
  column 3 to sit inside that list item. Indent it 2 spaces and the list terminates, every
  number restarts its own list, and the card renders `1. 1. 1.` — the failure seen on
  2026-08-12 and fixed by hand. Verified rendering correctly on a live card with this
  exact shape, no blank lines between the numbered items:

  ```
  1. Define the roles
     - What each role owns
     - What we need on day one
  2. Prepare the posts
     - Requirements
  ```

  The API is still no help in checking this: `desc` comes back byte-identical to what was
  sent, so the bug is invisible to any verification step and only eyeballing the card shows
  it. That is exactly why the indent rule is worth following blind — you cannot test for it
  after the fact, so get it right on the way in.

- **A rejected daily update, 2026-09-03, is why "Comment style" was rewritten.** The old
  section mandated a "What is new, live now:" / "\<Owner\> team need to work on these:"
  template and said "no jargon". Following both produced a draft that was rejected as
  not team facing and robotic, like typical generated text. Two separate causes.
  The template belongs to a feature announcement and was being applied to every recap; the
  board's own comments are topic heading plus terse first-person fragments, and reading four
  of them would have shown that in one call. And "no jargon" had stripped out 0DTE, Express,
  drawdown and spreads — the exact words the team writes themselves — leaving text that said
  nothing. **Read the card's existing comments before drafting, every time.** The voice to
  match is already in the feed; it is never worth guessing at.

- **`tr_get` is GET-only; extra args like `-X POST -d ...` are silently ignored.** 2026-10-05:
  assigning a member via `tr_get ".../idMembers" -X POST -d value=ID` returned `[]` (a GET of
  the empty member list), nothing assigned. Assign with a real POST:
  `curl -s -X POST "https://api.trello.com/1/cards/CARD_ID/idMembers?$AUTH" --data-urlencode "value=MEMBER_ID"`.
  Find member IDs with `tr_get "/1/boards/BOARD_ID/members"`.

## Card lifecycle (standard flow)
Every card follows: **create in "In Progress"** with a checklist of action items →
**tick each item ✅** as done (`tr_checkitem_set CARD ITEM complete` — state=complete
renders the checkmark) → when all done, **post a completion comment** (`tr_comment`,
team-facing style) → **move to the board's "Review" list** (`tr_card_move CARD REVIEW_LIST`).

### Writing a card
1. **Clarify first.** If the brief is ambiguous about what "done" means, or hides a fork that
   changes the whole card, ask **one** question and wait. Do not proceed on an assumption. The
   fork is usually "is this card the work already finished, or the work still left?".
2. **Decide everything now.** The card is written so that executing it is building, not deciding.
3. **Write the body** per "Card description style" above — first person, problem statement, short
   nested bullets, closing `Steps to work on`.
4. **Mirror the steps into a `Steps` checklist**, names only.
5. **Show the full draft and get confirmation before writing to Trello.**

Keep the working spec — the exact files to touch and a real shell verifier per step — **in the
conversation, not on the card**. It is what makes execution safe; it is not what the team reads.

### Executing a card
The executor is a builder reading a blueprint: do not re-design, do not expand scope.

- **Restate before touching anything** — every step, which are already ticked, which are blocked.
- **One step at a time**, the smallest change that satisfies it. Touch only the files agreed for
  that step; if a file was not named, do not touch it, however related it looks.
- **Verify before ticking, always.** Run a real command that exits 0 only if the step is truly
  done. Cards no longer carry `verify:` lines, so the executor chooses the command — and says
  which one it ran. Fix and retry **once**; still failing, leave it unticked and report the exact
  error rather than moving the goalposts.
- **Never tick on faith.** A tick means "checked", not "claimed". This matters most when you are
  confident, because that is exactly when skipping it is tempting.
- **If a verifier is a text check standing in for a build the toolchain cannot run here, say so.**
  Never report a grep as if it were a compile or a test.
- **One Trello write per Bash call** — batched writes silently fail.
- **Close out**: team-facing comment (what was done, what was skipped and why, what needs a
  human), then move to Review.
- **Stop before shipping.** No commit, no push, no deploy unless the user asks. Leave the diff.

## Board IDs
Look board and list IDs up with `tr_boards` and `tr_lists BOARD_ID`. Don't hard-code them here;
put your team's IDs in your own project docs.
