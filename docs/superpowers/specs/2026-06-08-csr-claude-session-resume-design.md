# csr — Claude Session Resume

**Date:** 2026-06-08
**Status:** Approved, ready for implementation

## Problem

Working across many Claude Code sessions in different projects/directories. Resuming
is painful: `/resume` is hard to navigate, and keeping `claude --resume <id>` commands
in a notes file is tedious to maintain. Need a fast, low-maintenance way to save the
sessions worth returning to and jump back into one.

## Solution

A single self-contained shell tool, `csr` (Claude Session Resume), that maintains a
**curated** list of bookmarked sessions and resumes them via a fuzzy picker. No browser,
no server, nothing written to `~/.claude`.

## Layout

Everything lives in one directory (this directory; safe to rename to `csr`):

```
<dir>/
  csr.sh              # the whole tool (resume picker + save + remove)
  csr-sessions.jsonl  # the curated store (created on first save)
  docs/superpowers/specs/2026-06-08-csr-claude-session-resume-design.md
```

Outside footprint: a single line in `~/.zshrc`:
```sh
source /absolute/path/to/csr.sh
```
Nothing is placed in `~/.claude`.

`csr.sh` resolves its own directory at runtime (from `${BASH_SOURCE[0]}` /
`${(%):-%x}` under zsh) so the store always sits next to the script. The directory
may be renamed or moved freely.

## Store format — `csr-sessions.jsonl`

One JSON object per line (JSONL chosen for append-one-line / drop-one-line simplicity
and corruption resilience; see design discussion). Minimal fields — display metadata
is read live from the session transcript, not snapshotted:

```json
{"sessionId":"e8334612-...","cwd":"/Users/.../claude-session","note":"slack phase 2","savedAt":"2026-06-08T12:00:00Z"}
```

## Locating a session transcript

Claude Code stores transcripts at:
```
~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl
```
where `<encoded-cwd>` is the absolute cwd with every `/` replaced by `-`
(e.g. `/Users/ashabhussan/Documents/claude-session` →
`-Users-ashabhussan-Documents-claude-session`).

From a store entry's `cwd` + `sessionId`, `csr` derives this path to read live metadata.

## Subcommands

### `csr save [note]`  — run inside a Claude session as `!csr save "note"`
- Reads `CLAUDE_CODE_SESSION_ID` (the current session) and `PWD` (the cwd) from the
  environment. The `!` prefix runs it in the session's shell, which already has these.
- If `CLAUDE_CODE_SESSION_ID` is unset, error out: "not inside a Claude Code session".
- Appends one JSONL line: `{sessionId, cwd, note, savedAt}` (savedAt = UTC ISO 8601).
- If the `sessionId` already exists in the store, update its note + savedAt instead of
  adding a duplicate (rewrite the file without the old line, then append the new one).
- Print a confirmation with the saved title/cwd.

### `csr`  — run in a normal terminal
- Read each line of the store. For each, locate the transcript and live-read:
  - `ai-title` (fall back to the first user prompt, then to "(untitled)")
  - `gitBranch`
  - last activity timestamp (max `timestamp` across records)
- If the transcript no longer exists, still list the entry but mark it `[missing]`.
- Sort by last activity, most recent first.
- Pipe into `fzf` with columns: relative-time · repo (basename of cwd) · branch · title · note.
- Preview pane: full cwd, note, and the first user prompt.
- **Enter** on a selection → `cd '<cwd>' && claude --resume '<sessionId>'`.
  (If the transcript is `[missing]`, refuse and warn instead of resuming.)
- **Ctrl-D** → remove the highlighted entry from the store (drop its line) and
  reload the list in place (`fzf --bind 'ctrl-d:execute-silent(...)+reload(...)'`).
- Empty store → friendly message explaining how to save with `!csr save`.

## Dependencies

- `fzf` (`brew install fzf`).
- `jq` for safe JSON read/write of store lines and parsing transcript records.
- On startup `csr` checks both are present and prints install hints if not.

## Out of scope (YAGNI)

- Auto-discovery of all sessions (the point is curation).
- Browser/HTML dashboard.
- Persistent notes editing from the picker (only add + remove; re-save updates a note).
- Launching new sessions, multi-machine sync.

## Open implementation notes

- Written for zsh (user's shell) but kept POSIX-ish; self-location handles both
  `${BASH_SOURCE}` and zsh's `${(%):-%x}`.
- All store mutations write to a temp file then `mv` over the original (atomic, avoids
  corruption if interrupted).
