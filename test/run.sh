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

echo
if [ "$_fails" -eq 0 ]; then echo "ALL PASS"; else echo "$_fails FAILED"; exit 1; fi
