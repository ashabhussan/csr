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

# --- build the fzf list (tab-separated; only DISPLAY field is shown) --------
# fields: epoch \t sessionId \t cwd \t DISPLAY
__list() {
  [ -f "$STORE" ] || return 0
  local line sid cwd note tf epoch rel repo branch title disp
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    sid="$(printf '%s' "$line"  | jq -r '.sessionId')"
    cwd="$(printf '%s' "$line"  | jq -r '.cwd')"
    note="$(printf '%s' "$line" | jq -r '.note // ""')"
    repo="$(basename "$cwd")"
    tf="$(_transcript "$sid")"
    if [ -n "$tf" ] && [ -f "$tf" ]; then
      epoch="$(stat -f %m "$tf" 2>/dev/null || echo 0)"
      rel="$(_reltime "$epoch")"
      branch="$(_branch "$tf")"; [ -z "$branch" ] && branch="-"
      title="$(_title "$tf")"
    else
      epoch=0; rel="⚠"; branch="-"; title="(missing transcript)"
    fi
    disp="$(printf '%4s  %-16s %-14s %-38s %s' \
      "$rel" "$(_truncate "$repo" 16)" "$(_truncate "$branch" 14)" \
      "$(_truncate "$title" 38)" "$([ -n "$note" ] && printf '· %s' "$note")")"
    printf '%s\t%s\t%s\t%s\n' "$epoch" "$sid" "$cwd" "$disp"
  done < "$STORE" | sort -t$'\t' -k1,1 -rn
}

# --- preview pane -----------------------------------------------------------
__preview() {
  local sid="$1" cwd="${2:-}" tf
  tf="$(_transcript "$sid")"
  echo "session : $sid"
  echo "cwd     : $cwd"
  if [ -n "$tf" ] && [ -f "$tf" ]; then
    echo "branch  : $(_branch "$tf")"
    echo "title   : $(_title "$tf")"
    echo "updated : $(date -r "$(stat -f %m "$tf")" '+%Y-%m-%d %H:%M')"
  else
    echo "status  : ⚠ transcript not found (session may have been deleted)"
  fi
  if [ -f "$STORE" ]; then
    local note
    note="$(grep -F "\"sessionId\":\"$sid\"" "$STORE" 2>/dev/null | tail -1 | jq -r '.note // ""' 2>/dev/null || true)"
    [ -n "$note" ] && { echo; echo "note    : $note"; }
  fi
  echo
  echo "resume  : cd '$cwd' && claude --resume '$sid'"
  if [ -n "$tf" ] && [ -f "$tf" ]; then
    echo
    echo "── first prompt ─────────────────────────────"
    grep -h '"type":"user"' "$tf" 2>/dev/null | head -1 | jq -r '
      (.message.content) as $c
      | if ($c|type)=="string" then $c
        elif ($c|type)=="array" then ([ $c[] | if type=="string" then . else (.text // "") end ] | join(" "))
        else "" end // ""' 2>/dev/null | fold -s -w 56 | head -12 || true
  fi
}

# --- remove one entry by session id -----------------------------------------
__remove() {
  local sid="$1" tmp
  [ -f "$STORE" ] || return 0
  tmp="$(mktemp)"
  jq -c "select(.sessionId != \"$sid\")" "$STORE" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$STORE"
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
  [ -f "$STORE" ] && jq -c "select(.sessionId != \"$sid\")" "$STORE" > "$tmp" 2>/dev/null || true
  jq -nc --arg s "$sid" --arg c "$cwd" --arg n "$note" --arg t "$savedAt" \
    '{sessionId:$s, cwd:$c, note:$n, savedAt:$t}' >> "$tmp"
  mv "$tmp" "$STORE"
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
  local self line sid cwd tf
  self="$(command -v csr || echo "$SCRIPT_DIR/csr.sh")"
  line="$( __list | fzf \
      --delimiter=$'\t' --with-nth=4 --nth=4 \
      --no-hscroll --reverse --height=90% \
      --header='enter: resume   ctrl-d: remove   esc: quit' \
      --preview="$self __preview {2} {3}" \
      --preview-window='down,45%,wrap' \
      --bind="ctrl-d:execute-silent($self __remove {2})+reload($self __list)" \
  )" || return 0
  [ -z "$line" ] && return 0
  sid="$(printf '%s' "$line" | cut -f2)"
  cwd="$(printf '%s' "$line" | cut -f3)"
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
