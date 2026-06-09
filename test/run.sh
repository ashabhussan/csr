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

CODEX_SID="aaaaaaaa-0000-7000-8000-000000000001"
CLAUDE_SID="bbbbbbbb-0000-4000-8000-000000000002"

assert_eq "_transcript locates codex rollout by uuid suffix" \
  "$CSR_CODEX_DIR/2026/06/09/rollout-2026-06-09T00-00-00-$CODEX_SID.jsonl" \
  "$(_transcript "$CODEX_SID" codex)"

assert_eq "_transcript locates claude transcript by id" \
  "$CSR_CLAUDE_DIR/-tmp-proj/$CLAUDE_SID.jsonl" \
  "$(_transcript "$CLAUDE_SID" claude)"

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

# a hand-edited empty "tool" must still render as claude (jq // only covers null/missing)
STORE_ET="$(mktemp)"
printf '{"tool":"","sessionId":"%s","cwd":"/tmp/proj","note":"","savedAt":"x"}\n' "$CLAUDE_SID" > "$STORE_ET"
assert_eq "__list renders empty-tool line as claude" \
  "1" "$(STORE="$STORE_ET" __list | awk -F'\t' '$4 ~ /claude/' | wc -l | tr -d ' ')"

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

echo
if [ "$_fails" -eq 0 ]; then echo "ALL PASS"; else echo "$_fails FAILED"; exit 1; fi
