# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Documentation checklist

When the user asks to "update the docs", review **all** doc files — they drift:

- `CLAUDE.md` — dev reference (this file): structure, flow, CLI flags, schema
- `README.md` — user-facing: usage, commands, key bindings
- `docs/config.md` — user-facing: profiles, providers, conventions, how-it-works
- `docs/teach.md` — user-facing: teach → distill → promote lifecycle

CLAUDE.md stays current via the dev loop; the others need explicit checking whenever user-facing behavior changes.

## What This Plugin Does

`novibe.nvim` is a minimal Neovim plugin for LazyVim. The user writes function skeletons (signatures + descriptive comments), visually selects them, and invokes the plugin. The selection is sent to the active AI CLI (Claude Code, opencode, or gemini) and streamed into a **fill-preview chat split**. `<CR>` applies in-scope code, then any out-of-scope changes (imports, types, other files) are reviewed one at a time.

**Philosophy:** the user is the architect. AI fills boilerplate within user-defined boundaries; it never makes architectural decisions.

## File Structure

```
lua/novibe/
  init.lua     — entry: selection capture, prompt assembly, vim.system, streams to chat
  config.lua   — defaults: bare, system_prompt, profiles, learn.auto_extract_after
  input.lua    — floating input window (:w submits, <Esc> cancels)
  chat.lua     — fill-preview split (M.open_fill) + legacy follow-up float (M.open);
                 question queue, streamed code via push(), #teach interception
  stream.lua   — escape-aware extractor for the "code" JSON field from partial stdout
  context.lua  — treesitter walk for the enclosing function/class signature
  diag.lua     — vim.diagnostic.get() output formatted for the selection range
  apply.lua    — content-based find/replace across files (strict then lenient pass)
  glob.lua     — glob → Lua pattern + section header matching
  no_vibe.lua  — loads NO_VIBE.md + .no_vibe/{convention,learned,map,rule,decision}-*.md,
                 filters by filename, stale detection via git log
  learn.lua    — #teach capture (.no_vibe/diffs.json) + distillation into learned-*.md
  promote.lua  — :NovibePromote — graduate mature rules (n≥3) into convention files
  consult.lua  — singleton interactive consult: seeds file/line/selection/conventions
  providers/   — claude.lua, opencode.lua, gemini.lua: find_bin, build_cmd,
                 parse_output, parse_chunk, streaming
plugin/novibe.lua — guard + user commands
```

## Core Flow

```
Visual select → input.lua float (:w submit)
  → prompt = system_prompt
           + matched convention/learned/knowledge sections (by filename)
           + treesitter enclosing signature
           + ctx_before + selection + ctx_after
           + LSP diagnostics for range
           + user instruction
  → fill-preview chat split opens (focus stays on working buffer)
  → provider streams stdout; stream.lua decodes the "code" field progressively
  → push(partial) renders into the split; spinner virt_lines anchor the selection
  → on completion: parse_output → { code, message, changes, done }
  → finalize() builds a question queue:
       Q1   = in-scope code (if non-empty)
       Q2.. = each entry in response.changes
  → one Q shown at a time with "[k/N]" winbar indicator. Per Q:
       <CR>      apply (splice for code-Q, apply.lua for change-Q), advance
       s         skip, advance
       :w <text> revise via AI anchored to current head Q; revised Qs replace head
                 (and change-Qs the AI already covers, by file); unreviewed tail Qs
                 (Q2, Q3…) are preserved
       :w #teach <reason>  capture reason as note-mode teach; no AI call, no queue change
       :w all    apply every remaining Q
       q         quit; applied Qs stay
  → queue exhausted or quit → chat closes
```

### Legacy follow-up split (M.open)

`M.open()` is still available for responses with only out-of-scope changes (no fillable code). Same `<CR>` / `:w discuss` / `q` semantics; `done:true` stays open until the user closes with `q`.

## Commands

- `:NovibeAct` — act on current line or range. Input float accepts:
  - free-form instruction → fill/modify the selection
  - `#teach <reason>` → accumulate evidence (diff if editing a recent fill, else note)
  - `#gen <description>` → project-level generation; AI proposes new files via `changes[action=create]`, reviewed file-by-file in the question queue
- `:NovibeConsult` — singleton interactive session in a vsplit. Process dies with buffer; `<Esc><Esc>` exits terminal mode; range injects selection. Seed = file, line, current commit hash, matched `.no_vibe` sections, snapshot instructions. Injected via `--append-system-prompt` (claude) or `--prompt-interactive` (gemini). AI may freely edit `CLAUDE.md` and `.no_vibe/*.md`; all other files off-limits. Say **"snapshot"** mid-session to persist discoveries. **opencode workaround:** no flag exists, so use `:NovibeConsultPrompt` after opening — the seed is `chansend`-ed into the input box; press Enter to submit.
- `:NovibeConsultPrompt` — build the consult seed from current buffer/selection and chansend it into the active consult terminal. Required for opencode; optional refresh for claude/gemini. Invoke from the source buffer, not the consult terminal.
- `:NovibeProfile` — two-step picker: slot (Act / Consult) then profile. Slots persist independently. No profile = CLI defaults.
- `:NovibeDistill` — distill accumulated `#teach` diffs into `.no_vibe/learned-*.md` (AI decides the topic split).
- `:NovibePromote` — graduate mature learned rules (n≥3) into canonical `.no_vibe/convention-*.md`; opens review split for inspection.

## CLI Invocation

Common flags across providers — only the relevant lines shown.

**Claude** (`provider = "claude"`):
```lua
-- streaming default (providers/claude.lua sets M.streaming = true):
{ claude_bin, "--continue", "--output-format", "stream-json",
  "--include-partial-messages", "--verbose", "--print", prompt }
-- + "--model", profile.model, "--effort", profile.effort   (when profile active)
-- + "--bare"                                                (when config.bare = true)
-- non-streaming fallback: "--output-format", "json"
```
`--continue` carries session context. `--bare` skips hooks/plugins/memory (safe only with `ANTHROPIC_API_KEY`, not `claude login`). Streaming: `parse_chunk` extracts `content_block_delta` text-deltas; `parse_output` scans for the final `type=="result"` line.

**opencode** (`provider = "opencode"`):
```lua
{ opencode_bin, "run", "--format", "json", prompt }
-- + "--model", profile.model, "--variant", profile.effort   (when profile active)
-- + "--session", session_id                                  (carries continuity)
```
No `--continue`; pass back the `sessionID` from the previous response as `--session`. No `--bare`.

**gemini** (`provider = "gemini"`):
```lua
{ gemini_bin, "--output-format", "stream-json", "--prompt", prompt }
-- + "--model", profile.model                                 (when profile active)
-- + "--session-id", session_id                                (carries continuity)
-- non-streaming fallback: "--output-format", "json"
```
No `--continue` (use `--session-id` with the prev response's UUID). No effort/variant equivalent. No `--bare`. Workspace must be trusted — run `gemini` once interactively or set `GEMINI_CLI_TRUST_WORKSPACE=true`. Streaming: `parse_chunk` extracts assistant `delta=true` events.

**`:NovibeConsult` (TUI mode):**
```lua
{ claude_bin,   "--append-system-prompt", seed }  -- + optional --model / --effort
{ opencode_bin }                                   -- no seed flag; use NovibeConsultPrompt
{ gemini_bin,   "--prompt-interactive",   seed }  -- + optional --model
```

## Profiles

User-defined in `setup()`. No defaults — must be explicit. No active profile = CLI defaults.

```lua
require("novibe").setup({
  profiles = {
    { label = "Claude Best",  provider = "claude",   model = "claude-opus-4-7",             effort = "max"  },
    { label = "Claude Fast",  provider = "claude",   model = "claude-haiku-4-5-20251001",   effort = "low"  },
    { label = "OC DeepSeek",  provider = "opencode", model = "opencode-go/deepseek-v4-pro", effort = "high" },
    { label = "Gemini Flash", provider = "gemini",   model = "gemini-2.0-flash"                             },
  }
})
```

- `provider`: `"claude"` (default) | `"opencode"` | `"gemini"`
- `effort` (claude): `low`/`medium`/`high`/`xhigh`/`max` → `--effort`
- `effort` (opencode): maps to `--variant` (values depend on model)
- `effort` (gemini): ignored
- `model` (claude): full ID (`claude-sonnet-4-6`) or alias (`sonnet`, `opus`)
- `model` (opencode): `"provider/model"` (run `opencode models`)
- `model` (gemini): full ID (run `gemini`, check `/model` in TUI)

## JSON Response Schema

Enforced by system prompt — all providers must return this shape:

```json
{
  "code": "modified selection only — spliced in place",
  "message": "question/explanation/proposal summary (null if none)",
  "changes": [
    { "file": "relative/path",
      "description": "human-readable summary",
      "action": "replace|insert_after|insert_before|create|delete",
      "find": "exact existing block (anchor)",
      "replace": "new code" }
  ],
  "done": true
}
```

`done:true` → apply and close. `done:false` → keep chat open for review.

## apply.lua: Content Matching

Never uses line numbers. Two-pass:
1. **Strict** — normalize (trim each line), match including blanks
2. **Lenient** — match non-empty lines only, tolerate blank-count differences

`action` values:
- `replace` / `insert_after` / `insert_before` — `find` is the anchor block
- `create` — `find` must be `""`; errors if the file exists
- `delete` — `find` and `replace` must be `""`; closes any open buffer for that file

## Convention, Learned Rule & Knowledge Base Files

Plugin walks up from `cwd`, then filters all sections by current filename — AI receives only matching sections, never the full content. Both `:NovibeAct` and `:NovibeConsult` use all layers.

Load order:
1. `NO_VIBE.md` at project root — single-file shortcut for simple projects
2. `.no_vibe/convention-*.md` — human-written coding rules
3. `.no_vibe/learned-*.md` — auto-distilled from `#teach`
4. `.no_vibe/map-*.md` — **dependency graph**: call chains, inheritance
5. `.no_vibe/rule-*.md` — **behavioral constraints**: e.g. "always use Class X as db proxy"
6. `.no_vibe/decision-*.md` — **architectural ADRs**: the why + rejected alternatives

Section format (all files):
```markdown
## always                ← loaded for every file
rules that always apply

## src/db/**             ← loaded only for files under src/db/
db-layer knowledge

## *.tsx, *.jsx          ← multiple globs, comma-separated
React rules
```
Headers are comma-separated globs (`*` = non-separator, `**` = any path). `always` matches everything.

### Knowledge Base: Stale Detection

`map-*` / `rule-*` / `decision-*` sections support `<!-- last-verified: HASH -->`:

```markdown
## src/db/**
<!-- last-verified: a3f9c2b -->
All db interactions go through Class X (src/db/proxy.ts).
```

On load, `no_vibe.lua` runs `git log HASH..HEAD -- <path>` for directory-style headers. New commits → section prefixed with `⚠ STALE: N commit(s) since HASH — verify before trusting.`

### Knowledge Base: Snapshot Workflow

Built exclusively in `:NovibeConsult`. Say **"snapshot"** to have the AI write a discovery to the right file with the current commit hash. Grows lazily, focused on areas you actually touch.

- `map-<area>.md` — structural (dependencies, call graphs)
- `rule-<area>.md` — behavioral (constraints on interacting with the area)
- `decision-<area>.md` — reasoning (why, what was rejected)

Keep entries concise — a pointer to what matters, not a copy of the code.

## #teach / Distillation Flow

`#teach <reason>` accumulates evidence into `.no_vibe/diffs.json`. Three entry points:

- **Diff mode** (`:NovibeAct`) — after a fill, edit the result, re-select, `:NovibeAct #teach <reason>`. The diff (original fill vs current selection) is captured.
- **Note mode** (`:NovibeAct`) — `:NovibeAct #teach <reason>` on any selection. Selection + reason captured; no `original` field.
- **Chat note mode** — `:w #teach <reason>` inside the fill-preview chat. Reason-only entry (no diff, no `current`) — chat feedback is verbal, so an AI→AI diff would be misleading. Side-effect only: no AI call, no queue change.

`:NovibeAct` picks diff vs note automatically: diff if `_last_fill` exists for the buffer and the selection differs from the last fill's output; otherwise note. Both require a non-empty reason if there's no diff to infer from.

Auto-distillation threshold:
- **1** when no `learned-*.md` exists yet (fresh project — fast feedback)
- `learn.auto_extract_after` (default 3) once any learned file exists

`M.extract()` sends accumulated diffs + existing `learned-*.md` to the AI to merge/dedupe and split by topic. Filenames must match `learned-[%w-]+%.md`. Diffs are cleared on success.
