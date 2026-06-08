#!/usr/bin/env bash
#
# csr — Claude Session Resume
# A curated, terminal bookmark list for Claude Code sessions.
#
#   csr            pick a saved session and resume it (fzf; Ctrl-D removes)
#   csr save [note]  save the CURRENT session  (run inside Claude as: !csr save "note")
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
PROJECTS_DIR="$HOME/.claude/projects"

# --- dependency check -------------------------------------------------------
_need() { command -v "$1" >/dev/null 2>&1 || { echo "csr: missing dependency '$1' ($2)" >&2; return 1; }; }

# --- find a session transcript by id (encoding-independent) -----------------
_transcript() {
  local sid="$1"
  find "$PROJECTS_DIR" -maxdepth 2 -name "$sid.jsonl" 2>/dev/null | head -1
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

_branch() {
  grep -h '"gitBranch"' "$1" 2>/dev/null | tail -1 | jq -r '.gitBranch // empty' 2>/dev/null || true
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

# --- build the fzf list (tab-separated; only DISPLAY field is shown) --------
# fields: epoch \t sessionId \t cwd \t DISPLAY
__list() {
  [ -f "$STORE" ] || return 0
  local line sid cwd note tf epoch rel repo branch title disp
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    sid="$(printf '%s' "$line"  | jq -r '.sessionId')"
    cwd="$(printf '%s' "$line"  | jq -r '.cwd')"
    note="$(printf '%s' "$line" | jq -r '.note // ""' | _clean)"
    repo="$(basename "$cwd" | _clean)"
    tf="$(_transcript "$sid")"
    if [ -n "$tf" ] && [ -f "$tf" ]; then
      epoch="$(stat -f %m "$tf" 2>/dev/null || echo 0)"
      rel="$(_reltime "$epoch")"
      branch="$(_branch "$tf" | _clean)"; [ -z "$branch" ] && branch="-"
      title="$(_title "$tf" | _clean)"
    else
      epoch=0; rel="⚠"; branch="-"; title="(missing transcript)"
    fi
    disp="$(printf '%4s  %-16s %-14s %-38s %s' \
      "$rel" "$(_truncate "$repo" 16)" "$(_truncate "$branch" 14)" \
      "$(_truncate "$title" 38)" "$([ -n "$note" ] && printf '· %s' "$note")")"
    # cwd is for display only here (resume re-reads it from the store by id);
    # _clean guarantees the row stays single-line and tab-delimited.
    printf '%s\t%s\t%s\t%s\n' "$epoch" "$(printf '%s' "$sid" | _clean)" "$(printf '%s' "$cwd" | _clean)" "$disp"
  done < "$STORE" | sort -t$'\t' -k1,1 -rn
}

# --- preview pane -----------------------------------------------------------
__preview() {
  local sid="$1" cwd="${2:-}" tf
  tf="$(_transcript "$sid")"
  # all fields below are sanitized before display: the preview pane processes
  # ANSI/escape sequences, and transcript/note text is untrusted.
  echo "session : $(printf '%s' "$sid" | _clean)"
  echo "cwd     : $(printf '%s' "$cwd" | _clean)"
  if [ -n "$tf" ] && [ -f "$tf" ]; then
    echo "branch  : $(_branch "$tf" | _clean)"
    echo "title   : $(_title "$tf" | _clean)"
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
  echo "resume  : cd '$(printf '%s' "$cwd" | _clean)' && claude --resume '$(printf '%s' "$sid" | _clean)'"
  if [ -n "$tf" ] && [ -f "$tf" ]; then
    echo
    echo "── first prompt ─────────────────────────────"
    grep -h '"type":"user"' "$tf" 2>/dev/null | head -1 | jq -r '
      (.message.content) as $c
      | if ($c|type)=="string" then $c
        elif ($c|type)=="array" then ([ $c[] | if type=="string" then . else (.text // "") end ] | join(" "))
        else "" end // ""' 2>/dev/null | _clean_multiline | fold -s -w 56 | head -12 || true
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

# --- save the current session -----------------------------------------------
cmd_save() {
  _need jq "brew install jq" || return 1
  local sid="${CLAUDE_CODE_SESSION_ID:-}" cwd="$PWD" note="$*" savedAt tmp
  if [ -z "$sid" ]; then
    echo "csr: CLAUDE_CODE_SESSION_ID is not set — run this inside a Claude Code session (e.g. !csr save \"note\")." >&2
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
  if jq -nc --arg s "$sid" --arg c "$cwd" --arg n "$note" --arg t "$savedAt" \
       '{sessionId:$s, cwd:$c, note:$n, savedAt:$t}' >> "$tmp"; then
    mv "$tmp" "$STORE"
  else
    rm -f "$tmp"; echo "csr: save failed; store left unchanged." >&2; return 1
  fi
  echo "csr: saved $(basename "$cwd")  ($sid)${note:+  — $note}"
}

# --- the picker -------------------------------------------------------------
cmd_pick() {
  _need fzf "brew install fzf" || return 1
  _need jq  "brew install jq"  || return 1
  if [ ! -s "$STORE" ]; then
    echo "csr: no saved sessions yet."
    echo "     Inside a Claude session, run:  !csr save \"a short note\""
    return 0
  fi
  local self selfq line sid cwd tf
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

main "$@"
