# csr — Codex support

**Date:** 2026-06-09
**Status:** Approved, ready for implementation
**Builds on:** [2026-06-08-csr-claude-session-resume-design.md](2026-06-08-csr-claude-session-resume-design.md)

## Problem

`csr` bookmarks and resumes **Claude Code** sessions only. The same workflow — save the
sessions worth returning to, fuzzy-pick one, resume instantly — applies just as well to
**Codex CLI** sessions. We want one curated list spanning both tools, not two separate
tools to remember.

A secondary cleanup: the note argument to `csr save` is optional, but several user-facing
strings imply it is required ("a short note"). Fix the wording to say it is optional.

## Solution

Teach `csr` that a saved session belongs to one of two tools — `claude` or `codex` — and
make every tool-specific operation (locate transcript, read cwd/branch/title, resume,
dependency check) dispatch on that tool. Everything else (the store, fuzzy picker, sort,
remove, preview frame) stays shared. Codex sessions are saved the same way Claude ones
are: `!csr save` from inside the session.

## Key facts about Codex (verified against this machine)

Codex CLI `0.137.0`, installed at `~/.nvm/.../@openai/codex`.

- **Session storage:** `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`
  (date-partitioned; `rollout-` prefix; the trailing `<uuid>` is the session id).
- **Session id == "thread id" == rollout UUID.** A session UUID like
  `019dcde0-996f-72e1-a2fa-08ab3d36762f` appears as the filename suffix **and** as
  `session_meta.payload.id` (line 1 of the transcript). This is exactly what
  `codex resume <uuid>` accepts.
- **Metadata is on line 1** (`{"type":"session_meta", ...}`): `payload.cwd`,
  `payload.git.branch`, `payload.git.commit_hash`, `payload.timestamp`.
- **No `ai-title`.** `~/.codex/session_index.jsonl` exists but is unreliable (1 of 210
  sessions present on this machine), so titles are **not** read from it. Title comes from
  the first real user prompt (see below).
- **`!` local shell escape exists.** The Codex TUI supports `!command` to "run it
  locally" (binary string: *"Prefix a command with ! to run it locally" / "Example:
  !ls"*). So `!csr save "..."` works inside Codex exactly like Claude.
- **`CODEX_THREAD_ID` is the env var** Codex exposes to commands it runs (it sits in
  Codex's shell-environment variable set alongside `SHELL`/`LC_ALL`/secret-exclusion
  patterns). Its value is the session UUID. This is the Codex analogue of
  `CLAUDE_CODE_SESSION_ID`.
- **Resume:** `codex resume <uuid>` (cwd-filtered unless `--all`, but an explicit UUID
  bypasses the filter).

### Single assumption to confirm before/at implementation

`CODEX_THREAD_ID` being populated in the `!` local-exec environment is inferred from the
binary, not executed. Confirm once with a one-liner inside a Codex session:

```
!echo "$CODEX_THREAD_ID"
```

Expect a UUID matching the current rollout filename. If for some reason it is empty, the
fallback is to read the newest rollout by mtime while the `!` command runs; this spec
assumes the env var works and does not implement the fallback unless that check fails.

## Save: symmetric env-var detection

`csr save [optional note]` selects the tool from whichever session env var is present:

| Env var present            | `tool`   | Session id taken from        |
|----------------------------|----------|------------------------------|
| `CLAUDE_CODE_SESSION_ID`   | `claude` | that value *(unchanged)*     |
| `CODEX_THREAD_ID`          | `codex`  | that value                   |
| neither                    | —        | **error**, save nothing      |

- No `--codex` flag and no `--claude` flag. Detection is automatic.
- Run in a plain terminal where neither var is set → error and exit non-zero:
  `csr: no Claude or Codex session detected — run inside a session (e.g. !csr save "note").`
- If, improbably, **both** are set (nested tools), prefer `CLAUDE_CODE_SESSION_ID`
  (keeps existing behavior deterministic). Document this precedence in a comment.
- De-dupe on `sessionId` exactly as today. Session UUIDs do not collide across tools, so
  no composite key is needed; the new `tool` field is stored for display/resume, not for
  identity.

## Store format — `csr-sessions.jsonl`

Add a `tool` field. Backward compatible: existing lines have no `tool` and are treated as
`"claude"` everywhere it is read.

```json
{"tool":"codex","sessionId":"019dcde0-...","cwd":"/Users/.../csr","note":"wip","savedAt":"2026-06-09T12:00:00Z"}
```

Read sites use `.tool // "claude"` so legacy entries keep working with no migration.

## Tool-aware lookups

Only these operations branch on `tool`; everything else is shared.

| Operation        | `claude`                                   | `codex`                                                  |
|------------------|--------------------------------------------|----------------------------------------------------------|
| Locate transcript| `find ~/.claude/projects -name "<sid>.jsonl"` | `find ~/.codex/sessions -name "rollout-*-<sid>.jsonl"` |
| cwd              | from store (resume) / transcript           | `session_meta` line 1 `payload.cwd`                      |
| branch           | last `"gitBranch"` line                     | `session_meta` line 1 `payload.git.branch`              |
| title            | `ai-title` → else first user prompt         | first user message whose text is **not** a `<…>` wrapper |
| updated (mtime)  | file mtime                                   | file mtime                                               |
| resume command   | `claude --resume <sid>`                      | `codex resume <sid>`                                     |
| dependency       | (none beyond core)                           | `codex` binary, checked only when resuming a codex row   |

### Codex title extraction

The first several `response_item` user/developer messages in a rollout are wrappers:
`developer` role (permissions/apps/skills/plugins instructions) and a `user` role
`<environment_context>…</environment_context>` block. The real first prompt is the first
`payload.type=="message"`, `role=="user"` entry whose joined text does **not** begin with
`<` (i.e. not a `<environment_context>` / `<...>` wrapper). Fall back to `(untitled)` if
none is found. Apply the same `_clean`/truncation already used for Claude titles.

### Implementation shape

- `_transcript sid tool` — dispatch the `find` pattern/root on `tool`.
- `_branch tf tool`, `_title tf tool` — dispatch the parser on `tool`.
- A small `_resume_cmd tool` (or inline `case`) producing the exec line.
- `__list` / `__preview` read `tool` per row (`.tool // "claude"`) and pass it down.
- The existing `_clean`, `_truncate`, `_reltime`, sort, `__remove`, and fzf wiring are
  unchanged.

## Unified picker

One list, recency-sorted (existing behavior), with a new fixed-width **tool tag** column
between the relative-time and repo columns: `cc` for Claude, `cx` for Codex. Because the
tag text contains "cc"/"cx" and the row remains fuzzy-searchable, typing `cx` or `codex`
narrows to Codex rows.

```
12m  cx  csr        main    Add codex support       · wip
 1h  cc  csa-api    dev     Refactor auth flow
 3h  cc  dorik-ui   feat/x  Fix modal z-index
```

Sanitization is unchanged: the tag is derived from the trusted `tool` field, all other
columns still pass through `_clean`.

### Preview pane

Add a `tool :` line and make the `resume :` line tool-correct:

```
session : 019dcde0-...
tool    : codex
cwd     : /Users/.../csr
branch  : main
title   : Add codex support
updated : 2026-06-09 12:00
note    : wip

resume  : cd '/Users/.../csr' && codex resume '019dcde0-...'

── first prompt ─────────────────────────────
...
```

For a missing transcript, the existing `⚠ transcript not found` path is reused per tool.

## Resume flow

On Enter, re-read `tool` and `cwd` from the store by `sessionId` (not from the display
row), locate the transcript with the tool-aware `_transcript`, and:

- `claude`: `cd "$cwd" && exec claude --resume "$sid"` *(unchanged)*
- `codex`:  `cd "$cwd" && exec codex resume "$sid"`

`cd` into the saved `cwd` first in both cases (matches Claude behavior and gives Codex its
repo context; the explicit UUID also bypasses Codex's cwd filter). If the `codex` binary
is missing at this point, error with the install hint rather than `exec`-ing.

## "Optional note" wording fix

The note is optional (`note="$*"` is empty when omitted, and an empty note is stored and
displayed fine). Update user-facing strings so none imply it is required:

- `csr.sh` empty-store hint (~line 191): `!csr save "a short note"` →
  `!csr save "an optional short note"`.
- Help/synopsis lines and `README.md`: present the argument as `save [optional note]`
  (or "optional short note") consistently. The synopsis already shows `[note]`; align the
  prose to call it optional.

This is wording-only; no behavior change.

## Out of scope

- No `--codex` / `--claude` save flags, no explicit-id save, no bookmarking arbitrary old
  sessions — saving is always "the current session" via the env var.
- No newest-rollout-by-mtime or recency-window heuristic (the env var makes it
  unnecessary).
- No reading from `~/.codex/session_index.jsonl`.
- No fork/archive/cloud Codex features — resume only.

## Testing

Manual, on real data (the tool is a thin shell wrapper over local files):

1. **Backward compat:** existing Claude entries (no `tool`) still list, preview, and
   resume; new Claude saves still work via `!csr save` (env var path unchanged).
2. **Codex save:** `!echo "$CODEX_THREAD_ID"` returns a UUID inside Codex; `!csr save
   "note"` writes a `{"tool":"codex",...}` line with that id.
3. **Plain-terminal save:** `csr save "x"` with neither env var set errors and writes
   nothing.
4. **List/preview:** mixed list shows `cc`/`cx` tags; Codex rows show correct cwd, branch,
   title (real first prompt, not `<environment_context>`), and a `codex resume` line.
5. **Resume:** picking a Codex row `cd`s to its cwd and `exec`s `codex resume <uuid>`;
   picking a Claude row is unchanged.
6. **Missing transcript:** a Codex row whose rollout was deleted shows `⚠` and refuses to
   resume.
7. **Wording:** empty-store hint and help/README describe the note as optional.
