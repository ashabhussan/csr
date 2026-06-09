#!/usr/bin/env bash
#
# csr — Claude Session Resume
# A curated, terminal bookmark list for Claude Code sessions.
#
#   csr            pick a saved session and resume it (fzf; Ctrl-D removes)
#   csr save [optional note]  save the CURRENT session (run inside Claude/Codex as: !csr save "note")
#
# Store lives next to this script as csr-sessions.jsonl (one JSON object per line).
# See docs/superpowers/specs/2026-06-08-csr-claude-session-resume-design.md
#
set -euo pipefail

# --- locate this script's real directory (resolve symlinks) -----------------
_src="${BASH_SOURCE[0]}"
while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
STORE="$SCRIPT_DIR/csr-sessions.jsonl"
PROJECTS_DIR="${CSR_CLAUDE_DIR:-$HOME/.claude/projects}"
CODEX_DIR="${CSR_CODEX_DIR:-$HOME/.codex/sessions}"

# --- dependency check -------------------------------------------------------
_need() { command -v "$1" >/dev/null 2>&1 || { echo "csr: missing dependency '$1' ($2)" >&2; return 1; }; }

# --- find a session transcript by id (encoding-independent) -----------------
_transcript() {
  local sid="$1" tool="${2:-claude}"
  case "$tool" in
    codex) find "$CODEX_DIR"    -maxdepth 4 -name "rollout-*-$sid.jsonl" 2>/dev/null | head -1 ;;
    *)     find "$PROJECTS_DIR" -maxdepth 2 -name "$sid.jsonl"           2>/dev/null | head -1 ;;
  esac
}

# --- human-friendly relative time from an epoch -----------------------------
_reltime() {
  local then="$1" now diff
  now="$(date +%s)"
  diff=$(( now - then ))
  if   [ "$diff" -lt 60 ];    then echo "now"
  elif [ "$diff" -lt 3600 ];  then echo "$(( diff / 60 ))m"
  elif [ "$diff" -lt 86400 ]; then echo "$(( diff / 3600 ))h"
  else echo "$(( diff / 86400 ))d"
  fi
}

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

_branch() {
  local tf="$1" tool="${2:-claude}"
  case "$tool" in
    codex) head -1 "$tf" 2>/dev/null | jq -r '.payload.git.branch // empty' 2>/dev/null || true ;;
    *)     grep -h '"gitBranch"' "$tf" 2>/dev/null | tail -1 | jq -r '.gitBranch // empty' 2>/dev/null || true ;;
  esac
}

_truncate() { # text width
  local s="$1" w="$2"
  if [ "${#s}" -gt "$w" ]; then printf '%s…' "${s:0:$((w-1))}"; else printf '%s' "$s"; fi
}

# collapse tab/newline/CR to spaces and drop all other control bytes (incl. ESC),
# so untrusted fields can't add fzf rows, shift columns, or emit terminal escapes.
# multibyte UTF-8 (e.g. … ⚠) is preserved: its bytes are >=0x80, outside [:cntrl:].
_clean() { LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C tr -d '[:cntrl:]'; }

# like _clean but keeps newlines (for multi-line preview text that gets folded)
_clean_multiline() { LC_ALL=C tr '\t\r' '  ' | LC_ALL=C tr -d '\000-\011\013-\037\177'; }

# POSIX single-quote a string for safe embedding in an fzf shell template
_shquote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# resume command for a tool (data-only; tool is the trusted store field)
_resume_cmd() { case "${1:-claude}" in codex) printf 'codex resume' ;; *) printf 'claude --resume' ;; esac; }

# --- build the fzf list (tab-separated; only DISPLAY field is shown) --------
# fields: epoch \t sessionId \t cwd \t DISPLAY
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

# --- remove one entry by session id -----------------------------------------
__remove() {
  local sid="$1" tmp
  [ -f "$STORE" ] || return 0
  tmp="$(mktemp)"
  # --arg keeps sid as data (never jq source); guard the mv so a jq failure
  # can't overwrite the store with an empty/partial file.
  if jq -c --arg s "$sid" 'select(.sessionId != $s)' "$STORE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STORE"
  else
    rm -f "$tmp"
    echo "csr: removal failed; store left unchanged." >&2
    return 1
  fi
}

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

# --- the picker -------------------------------------------------------------
cmd_pick() {
  _need fzf "brew install fzf" || return 1
  _need jq  "brew install jq"  || return 1
  if [ ! -s "$STORE" ]; then
    echo "csr: no saved sessions yet."
    echo "     Inside a Claude or Codex session, run:  !csr save \"an optional short note\""
    return 0
  fi
  local self selfq line sid cwd tf tool
  self="$(command -v csr || echo "$SCRIPT_DIR/csr.sh")"
  selfq="$(_shquote "$self")"   # safe even if the install path has spaces/metachars
  line="$( __list | fzf \
      --delimiter=$'\t' --with-nth=4 --nth=4 \
      --no-hscroll --reverse --height=90% \
      --header='enter: resume   ctrl-d: remove   esc: quit' \
      --preview="$selfq __preview {2} {3}" \
      --preview-window='down,45%,wrap' \
      --bind="ctrl-d:execute-silent($selfq __remove {2})+reload($selfq __list)" \
  )" || return 0
  [ -z "$line" ] && return 0
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
}

# --- dispatch ---------------------------------------------------------------
main() {
  local sub="${1:-}"
  case "$sub" in
    save)       shift; cmd_save "$@" ;;
    __list)     __list ;;
    __preview)  shift; __preview "$@" ;;
    __remove)   shift; __remove "$@" ;;
    -h|--help|help) sed -n '3,10p' "$_src" | sed 's/^# \{0,1\}//' ;;
    "" )        cmd_pick ;;
    *)          echo "csr: unknown command '$sub' (try: csr | csr save \"note\" | csr --help)" >&2; return 1 ;;
  esac
}

# Run only when executed directly, not when sourced (e.g. by test/run.sh).
[[ "${BASH_SOURCE[0]}" != "${0}" ]] || main "$@"
