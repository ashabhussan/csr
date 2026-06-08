# csr — Claude Session Resume

A curated, terminal bookmark list for Claude Code sessions. No browser, no server.
Save the sessions worth returning to, then fuzzy-pick one and resume it instantly.

## Install

Already done on this machine:

- `csr.sh` lives here; `~/.local/bin/csr` is a symlink to it (and `~/.local/bin` is on your `PATH`).
- Dependencies: `fzf` and `jq` (both installed).

On a fresh machine:

```sh
ln -sf /path/to/csr/csr.sh ~/.local/bin/csr   # ~/.local/bin must be on PATH
brew install fzf jq
```

The script resolves its own location, so this directory can be moved or renamed freely —
the store always stays next to `csr.sh`.

## Usage

**Save the current session** (run *inside* a Claude Code session, so it can read
`CLAUDE_CODE_SESSION_ID`):

```
!csr save "short note about what this session is"
```

**Resume** (in a normal terminal):

```
csr
```

- Fuzzy-type any part of the repo / branch / title / note.
- **Enter** → `cd` to the project and `claude --resume` that session.
- **Ctrl-D** → remove the highlighted entry from the list (in place).
- **Esc** → quit.

`csr --help` prints a summary.

## How it works

- The curated store is `csr-sessions.jsonl` — one JSON line per saved session:
  `{sessionId, cwd, note, savedAt}`.
- Display metadata (title, branch, last-activity) is **read live** from each session's
  transcript under `~/.claude/projects/`, so titles stay current and the store stays tiny.
- Transcripts are located by session id (not by encoded path), so renaming a project
  directory doesn't break lookups.

## Notes

- Entries whose transcript no longer exists are shown with a `⚠` and refuse to resume —
  remove them with Ctrl-D.
- `claude --resume` keys off the working directory, so resume runs from the original
  `cwd`. If you rename a project folder *after* saving, that older bookmark may not
  resume cleanly; just re-save it from the new location.
