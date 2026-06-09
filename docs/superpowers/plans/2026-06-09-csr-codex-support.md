# csr Codex Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `csr` so it bookmarks and resumes Codex CLI sessions alongside Claude Code sessions in one curated list.

**Architecture:** Add a `tool` field (`claude`|`codex`) to each store line. Only transcript lookup, branch/title parsing, the resume command, save-time session detection, and the dependency check branch on `tool`; the store, fuzzy picker, sort, remove, and preview frame stay shared. `tool` reaches `__preview` and the resume step via a store lookup by `sessionId` (mirroring the existing `note`/`cwd` lookups), so the tab-separated fzf row schema and `--with-nth/--nth/{2}/{3}` wiring are unchanged.

**Tech Stack:** Bash, `jq`, `fzf`, `find`, BSD `stat` (macOS). Codex CLI `0.138.0` stores sessions at `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`; the `<uuid>` is the session id (`= CODEX_THREAD_ID` env var inside a Codex session = `session_meta.payload.id`).

**Spec:** [docs/superpowers/specs/2026-06-09-csr-codex-support-design.md](../specs/2026-06-09-csr-codex-support-design.md)

---

## File Structure

- **Modify `csr.sh`** — all production changes live in this one file (it is the whole tool):
  - Make transcript roots env-overridable (`PROJECTS_DIR`, new `CODEX_DIR`).
  - Make `_transcript`, `_branch`, `_title` take a `tool` argument and dispatch.
  - Add `_resume_cmd` helper.
  - Make `cmd_save` detect the tool from env vars; derive Codex cwd from the rollout.
  - Make `__list` read `.tool`, render a full-word tag column, and call the tool-aware parsers.
  - Make `__preview` look up `tool` from the store and render a tool-correct preview/resume line.
  - Make `cmd_pick`'s resume step tool-aware (`codex resume`, codex dep check).
  - Guard the bottom-of-file `main "$@"` so the script is sourceable.
  - Fix "optional note" wording.
- **Create `test/run.sh`** — a tiny `bash` test runner (no framework) sourcing `csr.sh` and asserting on the pure parser functions.
- **Create `test/fixtures/...`** — synthetic Claude and Codex transcripts.
- **Modify `README.md`** — wording: present the note as optional.

---

## Task 1: Make the script sourceable + roots env-overridable + test harness

This is an **enabling refactor**: it lets every later test `source csr.sh` and point the
transcript roots at fixtures. There is no red-test-first step here because the only way to
"observe the failure" of an unsourceable script is to source it and have it launch the
interactive `fzf` picker on the real store — which hangs rather than fails cleanly. So we
make the two enabling edits first, then prove them with a green harness run.

**Files:**
- Modify: `csr.sh:233` (`main "$@"`), `csr.sh:23` (root dirs)
- Create: `test/run.sh`
- Create: `test/fixtures/claude/projects/.keep`, `test/fixtures/codex/sessions/.keep`

- [ ] **Step 1: Guard `main` so the script is sourceable**

In `csr.sh`, replace the last line:

```bash
main "$@"
```

with:

```bash
# Run only when executed directly, not when sourced (e.g. by test/run.sh).
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

- [ ] **Step 2: Make the transcript roots env-overridable**

In `csr.sh`, replace line 23:

```bash
PROJECTS_DIR="$HOME/.claude/projects"
```

with:

```bash
PROJECTS_DIR="${CSR_CLAUDE_DIR:-$HOME/.claude/projects}"
CODEX_DIR="${CSR_CODEX_DIR:-$HOME/.codex/sessions}"
```

- [ ] **Step 3: Create the test harness + fixture dirs**

Create `test/run.sh`:

```bash
#!/usr/bin/env bash
# csr test runner — sources csr.sh and asserts on its pure functions.
# Run: bash test/run.sh
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"

# point csr at fixtures, not the real machine
export CSR_CLAUDE_DIR="$HERE/fixtures/claude/projects"
export CSR_CODEX_DIR="$HERE/fixtures/codex/sessions"

# shellcheck disable=SC1090
source "$ROOT/csr.sh"   # must NOT run main() when sourced
set +eu                 # csr.sh sets -euo pipefail; relax -e/-u for the test driver

_fails=0
assert_eq() { # label expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n        expected: [%s]\n        actual:   [%s]\n' "$1" "$2" "$3"
    _fails=$((_fails+1))
  fi
}

# sanity: an existing pure function still works after sourcing
assert_eq "_truncate keeps short strings" "abc" "$(_truncate "abc" 16)"
assert_eq "_truncate truncates long strings" "abcde…" "$(_truncate "abcdefghij" 6)"

echo
if [ "$_fails" -eq 0 ]; then echo "ALL PASS"; else echo "$_fails FAILED"; exit 1; fi
```

Create the fixture dirs so the env paths exist:

```bash
mkdir -p test/fixtures/claude/projects test/fixtures/codex/sessions
touch test/fixtures/claude/projects/.keep test/fixtures/codex/sessions/.keep
```

- [ ] **Step 4: Run the harness to verify it passes (and does NOT launch the picker)**

Run: `bash test/run.sh`
Expected: `ok - _truncate ...` lines and `ALL PASS`, with no `fzf` picker appearing. If the picker opens, the `main` guard (Step 1) is wrong — fix before continuing.

- [ ] **Step 5: Commit**

```bash
git add csr.sh test/run.sh test/fixtures/claude/projects/.keep test/fixtures/codex/sessions/.keep
git commit -m "test(csr): make csr.sh sourceable and add fixture-based test harness"
```

---

## Task 2: Tool-aware transcript locator `_transcript`

**Files:**
- Modify: `csr.sh:29-32` (`_transcript`)
- Modify: `test/run.sh`
- Create: `test/fixtures/codex/sessions/2026/06/09/rollout-2026-06-09T00-00-00-aaaaaaaa-0000-7000-8000-000000000001.jsonl`
- Create: `test/fixtures/claude/projects/-tmp-proj/bbbbbbbb-0000-4000-8000-000000000002.jsonl`

- [ ] **Step 1: Create the fixtures**

Create `test/fixtures/codex/sessions/2026/06/09/rollout-2026-06-09T00-00-00-aaaaaaaa-0000-7000-8000-000000000001.jsonl` (4 lines — session_meta, developer wrapper, `<environment_context>` user wrapper, real prompt):

```jsonl
{"type":"session_meta","payload":{"id":"aaaaaaaa-0000-7000-8000-000000000001","cwd":"/tmp/proj","git":{"branch":"dev"},"cli_version":"0.138.0"}}
{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions>\n...sandbox...\n</permissions instructions>"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/tmp/proj</cwd>\n</environment_context>"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add codex support to csr"}]}}
```

Create `test/fixtures/claude/projects/-tmp-proj/bbbbbbbb-0000-4000-8000-000000000002.jsonl`:

```jsonl
{"type":"user","gitBranch":"main","message":{"content":"Build a session resumer"}}
{"type":"ai-title","aiTitle":"Session resumer tool"}
```

- [ ] **Step 2: Write the failing test**

Add to `test/run.sh` (before the final summary block):

```bash
CODEX_SID="aaaaaaaa-0000-7000-8000-000000000001"
CLAUDE_SID="bbbbbbbb-0000-4000-8000-000000000002"

assert_eq "_transcript locates codex rollout by uuid suffix" \
  "$CSR_CODEX_DIR/2026/06/09/rollout-2026-06-09T00-00-00-$CODEX_SID.jsonl" \
  "$(_transcript "$CODEX_SID" codex)"

assert_eq "_transcript locates claude transcript by id" \
  "$CSR_CLAUDE_DIR/-tmp-proj/$CLAUDE_SID.jsonl" \
  "$(_transcript "$CLAUDE_SID" claude)"
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bash test/run.sh`
Expected: the codex assertion FAILs — current `_transcript` ignores its tool arg and only searches `PROJECTS_DIR` for `<sid>.jsonl`, so it returns empty for the codex rollout.

- [ ] **Step 4: Make `_transcript` tool-aware**

Replace `csr.sh:29-32`:

```bash
_transcript() {
  local sid="$1"
  find "$PROJECTS_DIR" -maxdepth 2 -name "$sid.jsonl" 2>/dev/null | head -1
}
```

with:

```bash
_transcript() {
  local sid="$1" tool="${2:-claude}"
  case "$tool" in
    codex) find "$CODEX_DIR"    -maxdepth 4 -name "rollout-*-$sid.jsonl" 2>/dev/null | head -1 ;;
    *)     find "$PROJECTS_DIR" -maxdepth 2 -name "$sid.jsonl"           2>/dev/null | head -1 ;;
  esac
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash test/run.sh`
Expected: both `_transcript` assertions `ok`, `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add csr.sh test/run.sh test/fixtures
git commit -m "feat(csr): locate Codex rollouts by uuid (tool-aware _transcript)"
```

---

## Task 3: Tool-aware `_branch` and `_title` (Codex parsing)

**Files:**
- Modify: `csr.sh:46-63` (`_title`, `_branch`)
- Modify: `test/run.sh`

- [ ] **Step 1: Write the failing test**

Add to `test/run.sh`:

```bash
CODEX_TF="$(_transcript "$CODEX_SID" codex)"
CLAUDE_TF="$(_transcript "$CLAUDE_SID" claude)"

assert_eq "_branch reads codex git.branch from session_meta" \
  "dev" "$(_branch "$CODEX_TF" codex)"
assert_eq "_branch reads claude gitBranch" \
  "main" "$(_branch "$CLAUDE_TF" claude)"

assert_eq "_title codex skips <environment_context> wrapper" \
  "Add codex support to csr" "$(_title "$CODEX_TF" codex)"
assert_eq "_title claude prefers ai-title" \
  "Session resumer tool" "$(_title "$CLAUDE_TF" claude)"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/run.sh`
Expected: codex `_branch`/`_title` assertions FAIL — current functions only know the Claude format (`_branch` greps `"gitBranch"`; `_title` greps `"type":"user"`), so against a Codex rollout they return empty/`(untitled)`.

- [ ] **Step 3: Make `_title` tool-aware**

Replace `csr.sh:46-59` (the `_title` function):

```bash
# --- title for a transcript: ai-title, else first prompt, else fallback -----
_title() {
  local tf="$1" t
  t="$(grep -h '"type":"ai-title"' "$tf" 2>/dev/null | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null || true)"
  if [ -z "$t" ]; then
    t="$(grep -h '"type":"user"' "$tf" 2>/dev/null | head -1 | jq -r '
      (.message.content) as $c
      | if ($c|type)=="string" then $c
        elif ($c|type)=="array" then ([ $c[] | if type=="string" then . else (.text // "") end ] | join(" "))
        else "" end // empty' 2>/dev/null || true)"
  fi
  [ -z "$t" ] && t="(untitled)"
  printf '%s' "$t" | tr '\n' ' '
}
```

with:

```bash
# --- title for a transcript: ai-title, else first prompt, else fallback -----
# Codex has no ai-title; the first real user prompt is found by skipping the
# developer/instruction wrappers and the <environment_context> user message
# (any user message whose joined text begins with '<').
_title() {
  local tf="$1" tool="${2:-claude}" t
  case "$tool" in
    codex)
      t="$(grep -h '"type":"response_item"' "$tf" 2>/dev/null | jq -r '
        select(.payload.type=="message" and .payload.role=="user")
        | [ .payload.content[]? | (.text // "") ] | join(" ")' 2>/dev/null \
        | grep -vE '^[[:space:]]*<' | head -1 || true)"
      ;;
    *)
      t="$(grep -h '"type":"ai-title"' "$tf" 2>/dev/null | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null || true)"
      if [ -z "$t" ]; then
        t="$(grep -h '"type":"user"' "$tf" 2>/dev/null | head -1 | jq -r '
          (.message.content) as $c
          | if ($c|type)=="string" then $c
            elif ($c|type)=="array" then ([ $c[] | if type=="string" then . else (.text // "") end ] | join(" "))
            else "" end // empty' 2>/dev/null || true)"
      fi
      ;;
  esac
  [ -z "$t" ] && t="(untitled)"
  printf '%s' "$t" | tr '\n' ' '
}
```

- [ ] **Step 4: Make `_branch` tool-aware**

Replace `csr.sh:61-63` (the `_branch` function):

```bash
_branch() {
  grep -h '"gitBranch"' "$1" 2>/dev/null | tail -1 | jq -r '.gitBranch // empty' 2>/dev/null || true
}
```

with:

```bash
_branch() {
  local tf="$1" tool="${2:-claude}"
  case "$tool" in
    codex) head -1 "$tf" 2>/dev/null | jq -r '.payload.git.branch // empty' 2>/dev/null || true ;;
    *)     grep -h '"gitBranch"' "$tf" 2>/dev/null | tail -1 | jq -r '.gitBranch // empty' 2>/dev/null || true ;;
  esac
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash test/run.sh`
Expected: all `_branch`/`_title` assertions `ok`, `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add csr.sh test/run.sh
git commit -m "feat(csr): parse Codex branch and title (skip environment_context wrapper)"
```

---

## Task 4: `_resume_cmd` helper + tool-aware `__list` (tag column, legacy default)

**Files:**
- Modify: `csr.sh` (add `_resume_cmd`; rewrite `__list` body at `csr.sh:83-108`)
- Modify: `test/run.sh`

- [ ] **Step 1: Write the failing test**

Add to `test/run.sh`. This builds a temporary store with a Codex line, a Claude line, and a **legacy** line (no `tool`), then checks `__list` output:

```bash
STORE="$(mktemp)"   # csr.sh reads $STORE; override it for this test
cat > "$STORE" <<EOF
{"tool":"codex","sessionId":"$CODEX_SID","cwd":"/tmp/proj","note":"wip","savedAt":"2026-06-09T00:00:00Z"}
{"tool":"claude","sessionId":"$CLAUDE_SID","cwd":"/tmp/proj","note":"","savedAt":"2026-06-09T00:00:00Z"}
{"sessionId":"$CLAUDE_SID","cwd":"/tmp/proj","note":"legacy","savedAt":"2026-06-09T00:00:00Z"}
EOF

_list_out="$(__list)"

assert_eq "__list emits 4 tab-separated fields per row" \
  "4" "$(printf '%s\n' "$_list_out" | head -1 | awk -F'\t' '{print NF}')"
assert_eq "__list shows full-word codex tag in DISPLAY field" \
  "1" "$(printf '%s\n' "$_list_out" | awk -F'\t' '$4 ~ /codex/' | wc -l | tr -d ' ')"
assert_eq "__list renders legacy (no-tool) line as claude (2 claude rows)" \
  "2" "$(printf '%s\n' "$_list_out" | awk -F'\t' '$4 ~ /claude/' | wc -l | tr -d ' ')"

_resume_cmd_helper_check="$(_resume_cmd codex) :: $(_resume_cmd claude) :: $(_resume_cmd)"
assert_eq "_resume_cmd dispatches" "codex resume :: claude --resume :: claude --resume" "$_resume_cmd_helper_check"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/run.sh`
Expected: FAIL — `_resume_cmd` does not exist (errors), and `__list` does not yet emit a tag, so the `codex`/`claude` DISPLAY-match assertions fail.

- [ ] **Step 3: Add the `_resume_cmd` helper**

In `csr.sh`, add after the `_shquote` helper (around `csr.sh:79`):

```bash
# resume command for a tool (data-only; tool is the trusted store field)
_resume_cmd() { case "${1:-claude}" in codex) printf 'codex resume' ;; *) printf 'claude --resume' ;; esac; }
```

- [ ] **Step 4: Make `__list` tool-aware with a tag column**

Replace the `__list` body (`csr.sh:83-108`) with:

```bash
__list() {
  [ -f "$STORE" ] || return 0
  local line sid cwd tool note tf epoch rel repo branch title disp
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    sid="$(printf '%s' "$line"  | jq -r '.sessionId')"
    cwd="$(printf '%s' "$line"  | jq -r '.cwd')"
    tool="$(printf '%s' "$line" | jq -r '.tool // "claude"')"
    note="$(printf '%s' "$line" | jq -r '.note // ""' | _clean)"
    repo="$(basename "$cwd" | _clean)"
    tf="$(_transcript "$sid" "$tool")"
    if [ -n "$tf" ] && [ -f "$tf" ]; then
      epoch="$(stat -f %m "$tf" 2>/dev/null || echo 0)"
      rel="$(_reltime "$epoch")"
      branch="$(_branch "$tf" "$tool" | _clean)"; [ -z "$branch" ] && branch="-"
      title="$(_title "$tf" "$tool" | _clean)"
    else
      epoch=0; rel="⚠"; branch="-"; title="(missing transcript)"
    fi
    # tag is the trusted .tool value (claude|codex); spelled in full so the
    # fzf search (restricted to this DISPLAY field) matches a typed "codex".
    disp="$(printf '%4s  %-7s %-16s %-14s %-38s %s' \
      "$rel" "$tool" "$(_truncate "$repo" 16)" "$(_truncate "$branch" 14)" \
      "$(_truncate "$title" 38)" "$([ -n "$note" ] && printf '· %s' "$note")")"
    # cwd is display-only here (resume re-reads it from the store by id);
    # _clean guarantees the row stays single-line and tab-delimited.
    printf '%s\t%s\t%s\t%s\n' "$epoch" "$(printf '%s' "$sid" | _clean)" "$(printf '%s' "$cwd" | _clean)" "$disp"
  done < "$STORE" | sort -t$'\t' -k1,1 -rn
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash test/run.sh`
Expected: all `__list`/`_resume_cmd` assertions `ok`, `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add csr.sh test/run.sh
git commit -m "feat(csr): show tool tag in picker and add _resume_cmd (legacy lines = claude)"
```

---

## Task 5: Save-time session detection (Claude + Codex env vars)

**Files:**
- Modify: `csr.sh:160-183` (`cmd_save`)
- Modify: `test/run.sh`

- [ ] **Step 1: Write the failing test**

Add to `test/run.sh`. These drive `cmd_save` with a fresh temp store and assert on the stored line. The Codex case relies on the Task 2 fixture so `cmd_save` can derive cwd from `session_meta`:

```bash
# --- save: Codex via CODEX_THREAD_ID, cwd derived from the rollout meta ---
STORE="$(mktemp)"; : > "$STORE"
( unset CLAUDE_CODE_SESSION_ID; export CODEX_THREAD_ID="$CODEX_SID"; cmd_save "hello codex" >/dev/null )
assert_eq "save records codex tool"   "codex"               "$(jq -r '.tool' "$STORE")"
assert_eq "save records codex id"     "$CODEX_SID"          "$(jq -r '.sessionId' "$STORE")"
assert_eq "save derives cwd from meta" "/tmp/proj"          "$(jq -r '.cwd' "$STORE")"
assert_eq "save records note"         "hello codex"         "$(jq -r '.note' "$STORE")"

# --- save: Claude via CLAUDE_CODE_SESSION_ID, cwd = PWD ---
STORE="$(mktemp)"; : > "$STORE"
( unset CODEX_THREAD_ID; export CLAUDE_CODE_SESSION_ID="$CLAUDE_SID"; cd /tmp && cmd_save >/dev/null )
assert_eq "save records claude tool"  "claude"              "$(jq -r '.tool' "$STORE")"
assert_eq "save records claude id"    "$CLAUDE_SID"         "$(jq -r '.sessionId' "$STORE")"
assert_eq "save claude cwd is PWD"    "/tmp"                "$(jq -r '.cwd' "$STORE")"
assert_eq "save empty note is empty"  ""                    "$(jq -r '.note' "$STORE")"

# --- save: neither env var → error, nothing written ---
STORE="$(mktemp)"; : > "$STORE"
( unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID; cmd_save "x" >/dev/null 2>&1 )
assert_eq "save with no session writes nothing" "0" "$(wc -l < "$STORE" | tr -d ' ')"
```

> Note: on macOS `cd /tmp` reports `/tmp` (a symlink to `/private/tmp`) as `$PWD` because `cd` keeps the logical path; the assertion uses `/tmp`. If a future shell resolves it physically, adjust the expected value to `/private/tmp`.

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/run.sh`
Expected: FAIL — current `cmd_save` requires `CLAUDE_CODE_SESSION_ID`, never reads `CODEX_THREAD_ID`, writes no `tool` field, and always uses `$PWD` for cwd.

- [ ] **Step 3: Rewrite `cmd_save`**

Replace `cmd_save` (`csr.sh:160-183`) with:

```bash
# --- save the current session (auto-detects Claude vs Codex from env) -------
cmd_save() {
  _need jq "brew install jq" || return 1
  local tool sid cwd="$PWD" note="$*" savedAt tmp tf mcwd
  # Precedence: if both are somehow set (nested tools), prefer Claude so
  # existing behavior stays deterministic.
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    tool="claude"; sid="$CLAUDE_CODE_SESSION_ID"
  elif [ -n "${CODEX_THREAD_ID:-}" ]; then
    tool="codex"; sid="$CODEX_THREAD_ID"
    # Prefer the authoritative project dir from the rollout's session_meta;
    # the '!' shell's PWD may differ from the Codex session cwd.
    tf="$(_transcript "$sid" codex)"
    if [ -n "$tf" ] && [ -f "$tf" ]; then
      mcwd="$(head -1 "$tf" | jq -r '.payload.cwd // empty' 2>/dev/null || true)"
      [ -n "$mcwd" ] && cwd="$mcwd"
    fi
  else
    echo "csr: no Claude or Codex session detected — run inside a session (e.g. !csr save \"an optional note\")." >&2
    return 1
  fi
  savedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp)"
  # de-dupe existing entries (--arg keeps sid as data). Abort on read failure so
  # a malformed store is never silently replaced by just the new entry.
  if [ -f "$STORE" ] && ! jq -c --arg s "$sid" 'select(.sessionId != $s)' "$STORE" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "csr: could not read existing store; aborting to avoid data loss." >&2
    return 1
  fi
  if jq -nc --arg tool "$tool" --arg s "$sid" --arg c "$cwd" --arg n "$note" --arg t "$savedAt" \
       '{tool:$tool, sessionId:$s, cwd:$c, note:$n, savedAt:$t}' >> "$tmp"; then
    mv "$tmp" "$STORE"
  else
    rm -f "$tmp"; echo "csr: save failed; store left unchanged." >&2; return 1
  fi
  echo "csr: saved [$tool] $(basename "$cwd")  ($sid)${note:+  — $note}"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash test/run.sh`
Expected: all save assertions `ok`, `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add csr.sh test/run.sh
git commit -m "feat(csr): auto-detect Claude/Codex session at save time via env vars"
```

---

## Task 6: Tool-aware `__preview` and resume

**Files:**
- Modify: `csr.sh:111-141` (`__preview`)
- Modify: `csr.sh:194-217` (resume tail of `cmd_pick`)
- Modify: `test/run.sh`

- [ ] **Step 1: Write the failing test**

Add to `test/run.sh`. The preview reads `tool` from `$STORE` by id, so seed a store first:

```bash
STORE="$(mktemp)"
cat > "$STORE" <<EOF
{"tool":"codex","sessionId":"$CODEX_SID","cwd":"/tmp/proj","note":"wip","savedAt":"2026-06-09T00:00:00Z"}
EOF
_prev="$(__preview "$CODEX_SID" "/tmp/proj")"

assert_eq "preview shows tool line" \
  "1" "$(printf '%s\n' "$_prev" | grep -c '^tool    : codex')"
assert_eq "preview shows codex resume command" \
  "1" "$(printf '%s\n' "$_prev" | grep -c 'codex resume')"
assert_eq "preview shows codex branch from meta" \
  "1" "$(printf '%s\n' "$_prev" | grep -c '^branch  : dev')"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/run.sh`
Expected: FAIL — current `__preview` has no `tool` line, always prints `claude --resume`, and parses branch with the Claude grep (empty for a Codex rollout).

- [ ] **Step 3: Rewrite `__preview`**

Replace `__preview` (`csr.sh:111-141`) with:

```bash
# --- preview pane -----------------------------------------------------------
__preview() {
  local sid="$1" cwd="${2:-}" tf tool
  # tool is not carried in the fzf row; look it up from the store by id,
  # exactly like the note lookup below (keeps the row schema unchanged).
  tool="$(jq -r --arg s "$sid" 'select(.sessionId==$s) | .tool // "claude"' "$STORE" 2>/dev/null | tail -1 || true)"
  [ -z "$tool" ] && tool="claude"
  tf="$(_transcript "$sid" "$tool")"
  # all fields below are sanitized before display: the preview pane processes
  # ANSI/escape sequences, and transcript/note text is untrusted.
  echo "session : $(printf '%s' "$sid" | _clean)"
  echo "tool    : $tool"
  echo "cwd     : $(printf '%s' "$cwd" | _clean)"
  if [ -n "$tf" ] && [ -f "$tf" ]; then
    echo "branch  : $(_branch "$tf" "$tool" | _clean)"
    echo "title   : $(_title "$tf" "$tool" | _clean)"
    echo "updated : $(date -r "$(stat -f %m "$tf")" '+%Y-%m-%d %H:%M')"
  else
    echo "status  : ⚠ transcript not found (session may have been deleted)"
  fi
  if [ -f "$STORE" ]; then
    local note
    note="$(jq -r --arg s "$sid" 'select(.sessionId==$s) | .note // ""' "$STORE" 2>/dev/null | tail -1 | _clean || true)"
    [ -n "$note" ] && { echo; echo "note    : $note"; }
  fi
  echo
  echo "resume  : cd '$(printf '%s' "$cwd" | _clean)' && $(_resume_cmd "$tool") '$(printf '%s' "$sid" | _clean)'"
  if [ -n "$tf" ] && [ -f "$tf" ]; then
    echo
    echo "── first prompt ─────────────────────────────"
    if [ "$tool" = "codex" ]; then
      grep -h '"type":"response_item"' "$tf" 2>/dev/null | jq -r '
        select(.payload.type=="message" and .payload.role=="user")
        | [ .payload.content[]? | (.text // "") ] | join(" ")' 2>/dev/null \
        | grep -vE '^[[:space:]]*<' | head -1 | _clean_multiline | fold -s -w 56 | head -12 || true
    else
      grep -h '"type":"user"' "$tf" 2>/dev/null | head -1 | jq -r '
        (.message.content) as $c
        | if ($c|type)=="string" then $c
          elif ($c|type)=="array" then ([ $c[] | if type=="string" then . else (.text // "") end ] | join(" "))
          else "" end // ""' 2>/dev/null | _clean_multiline | fold -s -w 56 | head -12 || true
    fi
  fi
}
```

- [ ] **Step 4: Make the resume step tool-aware**

In `cmd_pick`, replace the tail from the `sid="..."` extraction through the final `exec` (`csr.sh:206-216`):

```bash
  sid="$(printf '%s' "$line" | cut -f2)"
  # re-read cwd from the store by id (not the display field) so resume always
  # uses the exact saved path, regardless of display sanitization.
  cwd="$(jq -r --arg s "$sid" 'select(.sessionId==$s) | .cwd' "$STORE" 2>/dev/null | tail -1)"
  tf="$(_transcript "$sid")"
  if [ -z "$tf" ] || [ ! -f "$tf" ]; then
    echo "csr: transcript for $sid not found — cannot resume. (Remove it with Ctrl-D.)" >&2
    return 1
  fi
  echo "csr: resuming in $cwd …"
  cd "$cwd" && exec claude --resume "$sid"
```

with:

```bash
  sid="$(printf '%s' "$line" | cut -f2)"
  # re-read tool + cwd from the store by id (not the display row) so resume
  # always uses the exact saved values, regardless of display sanitization.
  tool="$(jq -r --arg s "$sid" 'select(.sessionId==$s) | .tool // "claude"' "$STORE" 2>/dev/null | tail -1)"
  [ -z "$tool" ] && tool="claude"
  cwd="$(jq -r --arg s "$sid" 'select(.sessionId==$s) | .cwd' "$STORE" 2>/dev/null | tail -1)"
  tf="$(_transcript "$sid" "$tool")"
  if [ -z "$tf" ] || [ ! -f "$tf" ]; then
    echo "csr: transcript for $sid not found — cannot resume. (Remove it with Ctrl-D.)" >&2
    return 1
  fi
  if [ "$tool" = "codex" ]; then
    _need codex "npm i -g @openai/codex" || return 1
  fi
  echo "csr: resuming [$tool] in $cwd …"
  case "$tool" in
    codex) cd "$cwd" && exec codex resume "$sid" ;;
    *)     cd "$cwd" && exec claude --resume "$sid" ;;
  esac
```

Also update the local declaration line in `cmd_pick` (`csr.sh:194`) to include `tool`:

```bash
  local self selfq line sid cwd tf
```

becomes:

```bash
  local self selfq line sid cwd tf tool
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash test/run.sh`
Expected: all preview assertions `ok`, `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add csr.sh test/run.sh
git commit -m "feat(csr): tool-aware preview and resume (codex resume + dep check)"
```

---

## Task 7: "Optional note" wording

**Files:**
- Modify: `csr.sh:7` (header synopsis used by `--help`), `csr.sh:191` (empty-store hint)
- Modify: `README.md`

- [ ] **Step 1: Fix the empty-store hint**

In `csr.sh`, the `cmd_pick` empty-store branch (~`csr.sh:191`):

```bash
    echo "     Inside a Claude session, run:  !csr save \"a short note\""
```

becomes (also generalize "Claude" → "Claude or Codex" since both are supported now):

```bash
    echo "     Inside a Claude or Codex session, run:  !csr save \"an optional short note\""
```

- [ ] **Step 2: Fix the `--help` synopsis line**

In `csr.sh:7` (printed by `csr --help`, which `sed`s lines 3-10):

```bash
#   csr save [note]  save the CURRENT session  (run inside Claude as: !csr save "note")
```

becomes:

```bash
#   csr save [optional note]  save the CURRENT session (run inside Claude/Codex as: !csr save "note")
```

- [ ] **Step 3: Update README.md**

In `README.md`, update the **Save** section so it covers both tools and calls the note optional. Replace the paragraph + code block under "**Save the current session**":

```markdown
**Save the current session** (run *inside* a Claude Code session, so it can read
`CLAUDE_CODE_SESSION_ID`):

```
!csr save "short note about what this session is"
```
```

with:

```markdown
**Save the current session** — run *inside* a Claude Code **or** Codex session via the
`!` shell escape. `csr` auto-detects which tool you are in (`CLAUDE_CODE_SESSION_ID` for
Claude, `CODEX_THREAD_ID` for Codex). The note is **optional**:

```
!csr save                                  # no note
!csr save "short note about this session"  # with a note
```

Run in a plain terminal where neither variable is set and `csr save` errors without
writing anything.
```

Also update the **How it works** bullet that describes the store line to mention `tool`:

```markdown
- The curated store is `csr-sessions.jsonl` — one JSON line per saved session:
  `{sessionId, cwd, note, savedAt}`.
```

becomes:

```markdown
- The curated store is `csr-sessions.jsonl` — one JSON line per saved session:
  `{tool, sessionId, cwd, note, savedAt}` (`tool` is `claude` or `codex`; lines without
  it are treated as `claude`).
```

- [ ] **Step 4: Verify help renders and wording is correct**

Run: `./csr.sh --help`
Expected: output includes `csr save [optional note]  save the CURRENT session ...` with no errors.

- [ ] **Step 5: Commit**

```bash
git add csr.sh README.md
git commit -m "docs(csr): describe save note as optional and cover Codex"
```

---

## Task 8: Full regression + manual real-data verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full automated test**

Run: `bash test/run.sh`
Expected: every line `ok`, final line `ALL PASS`.

- [ ] **Step 2: Confirm the `CODEX_THREAD_ID` assumption on real Codex**

Inside any live Codex session, run:

```
!echo "$CODEX_THREAD_ID"
```

Expected: a UUID that matches the `<uuid>` in the current `~/.codex/sessions/.../rollout-*-<uuid>.jsonl`. If it is **empty**, stop and report — the save path's Codex detection depends on this; the spec's fallback (newest rollout by mtime) would then need to be added.

- [ ] **Step 3: Real Codex save + list + resume (smoke)**

Inside a live Codex session: `!csr save "codex smoke test"`.
Then in a normal terminal: `csr`.
Expected: a `codex`-tagged row appears; its preview shows the real first prompt (not `<environment_context>`), the correct branch/cwd, and a `codex resume <uuid>` line. Selecting it `cd`s to the saved cwd and launches `codex resume`.

- [ ] **Step 4: Backward-compatibility check**

Confirm a pre-existing Claude entry (a store line with no `tool`) still lists with a `claude` tag, previews, and resumes via `claude --resume`. Confirm a fresh `!csr save` inside Claude still works and now writes a `"tool":"claude"` line.

- [ ] **Step 5: Plain-terminal save error**

In a normal terminal (no Claude/Codex env vars): `csr save "x"`.
Expected: prints the "no Claude or Codex session detected" error, exits non-zero, store unchanged.

- [ ] **Step 6: Final commit (if any verification fixes were needed)**

```bash
git add -A
git commit -m "test(csr): verify Codex support end-to-end"
```

(If no fixes were required, skip — Step 1 already passed and prior tasks committed.)
