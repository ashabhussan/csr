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

Codex CLI `0.138.0`, installed at `~/.nvm/.../@openai/codex`. (Note: a transcript's
`session_meta.payload.cli_version` records the version that *started* that session, so
older rollouts can show an earlier value — e.g. `0.137.0` — even after the binary is
updated. Do not treat it as the installed version.)

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
- **Where `tool` comes from at each site (no row-schema change):**
  - `__list` already reads each store line with `jq`; add `.tool // "claude"` there to
    render the tag column and to call the tool-aware `_transcript`/`_branch`/`_title`.
  - `__preview` and the resume step look `tool` up **from the store by `sessionId`**,
    exactly the way `__preview` already re-reads `note` (csr.sh:127) and the resume step
    already re-reads `cwd` (csr.sh:209). They do **not** receive `tool` through the fzf
    row.
- **Therefore the tab-separated row stays `epoch \t sessionId \t cwd \t DISPLAY`** and the
  fzf wiring (`--with-nth=4 --nth=4`, preview `{2} {3}`, `cut -f2`, ctrl-d `{2}`) is
  unchanged. Do **not** insert `tool` as a hidden row field — doing so would shift the
  positional placeholders and break preview/resume.
- The existing `_clean`, `_truncate`, `_reltime`, sort, and `__remove` are unchanged.

## Unified picker

One list, recency-sorted (existing behavior), with a new fixed-width **tool tag** column
between the relative-time and repo columns. The tag spells the tool in full — `claude` /
`codex` — padded to a fixed width, rather than a `cc`/`cx` abbreviation.

Rationale: fzf is configured with `--with-nth=4 --nth=4`, so **search is restricted to
the visible DISPLAY field only** — hidden fields are not searched. The tag is part of the
DISPLAY field, so spelling it `codex`/`claude` makes typing `codex` (or `claude`) actually
narrow the list. A `cx`/`cc` abbreviation would only match `cx`/`cc`, not `codex`/`claude`.

```
12m  codex   csr        main    Add codex support       · wip
 1h  claude  csa-api    dev     Refactor auth flow
 3h  claude  dorik-ui   feat/x  Fix modal z-index
```

Sanitization is unchanged: the tag is derived from the trusted `tool` field, all other
columns still pass through `_clean`. The `printf` width spec for `disp` gains one
fixed-width column for the tag (e.g. `%-7s`).

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

### One automated fixture test (new)

The highest-risk logic is the parsers (hidden-field ordering, legacy `.tool // "claude"`
default, and Codex title extraction skipping `<environment_context>`). Add a single small
test script — `test/run.sh` plus synthetic fixtures under `test/fixtures/` — that sources
`csr.sh`'s pure functions and asserts on their output. No framework; plain `bash` with a
trivial `assert_eq`. It must cover:

- A synthetic **Codex** rollout (`session_meta` line 1 with `payload.cwd` / `git.branch`,
  then a `developer` wrapper, a `<environment_context>` user message, then the real first
  user prompt): `_title … codex` returns the real prompt, **not** the wrapper; `_branch`
  and the cwd parse from line 1.
- A synthetic **Claude** transcript: `_title`/`_branch` unchanged from current behavior.
- A store with a **legacy line lacking `tool`**: it is treated as `claude` (`.tool //
  "claude"`) by `__list` and the resume lookup.
- `__list` output for a mixed store: row stays `epoch \t sid \t cwd \t DISPLAY` (4
  tab-fields) and DISPLAY contains the full-word tag.

Fixtures use fake session ids and a `PROJECTS_DIR`/`~/.codex` override (or a temp HOME) so
the test does not depend on real local sessions.

To make the functions sourceable, guard the bottom-of-file call so `main` runs only when
the script is executed, not when sourced:
`[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"` (replacing the bare `main "$@"`). The
Codex/Claude transcript roots (`PROJECTS_DIR`, and the new `~/.codex/sessions` root)
should be overridable via env vars defaulting to the current paths, so the test can point
them at `test/fixtures/`.

### Manual, on real data (the tool is a thin shell wrapper over local files):

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
