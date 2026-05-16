# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Plugin Does

`novibe.nvim` is a minimal Neovim plugin for LazyVim. The user writes function skeletons — signatures plus descriptive comments — visually selects the block, and invokes the plugin. The selection is sent to the active AI CLI (Claude Code, opencode, or gemini) and streamed into a **fill-preview chat split** for review. The user presses `<CR>` to apply the code to the working buffer, then reviews any out-of-scope changes (imports, types, other files) in a second phase before applying them.

**Philosophy:** the user is the architect. Claude fills boilerplate within boundaries the user defined. AI never makes architectural decisions.

## File Structure

```
lua/novibe/
  init.lua     — entry point: selection capture, prompt assembly, vim.system call, streams chunks to fill-preview chat
  config.lua   — defaults: bare flag, system_prompt, profiles, learn.auto_extract_after
  input.lua    — floating input window (:w submits, <Esc> cancels)
  chat.lua     — fill-preview chat split (M.open_fill) + multi-turn follow-up float (M.open); two-phase confirm (code → out-of-scope changes); schema reminder; streams partial code via push()
  stream.lua   — escape-aware extractor for the "code" JSON string field from partial provider stdout (handles \", \\, \n, \uXXXX)
  context.lua  — treesitter walk to find the enclosing function/class signature above the visible context window
  diag.lua     — formats vim.diagnostic.get() output for the selection's line range, appended to the prompt
  apply.lua    — content-based find-and-replace across files (two-pass: strict then lenient)
  glob.lua     — glob → Lua pattern conversion + section header matching
  no_vibe.lua  — loads NO_VIBE.md + .no_vibe/convention-*.md + .no_vibe/learned-*.md + knowledge base (map/rule/decision), filters by filename; stale detection via git log
  learn.lua    — #teach diff capture (.no_vibe/diffs.json) + distillation into learned-*.md topic files
  promote.lua  — :NovibePromote flow: reads learned-*.md + convention-*.md, asks AI to graduate mature rules (n≥3) into convention files; opens M.open for review
  consult.lua  — singleton interactive consult: opens in current window, seeds file/line/selection/conventions; supports claude, opencode, gemini TUI
  providers/   — claude.lua, opencode.lua, gemini.lua — each exposes find_bin, build_cmd, parse_output, parse_chunk, streaming
plugin/
  novibe.lua   — guard + :NovibeAct, :NovibeConsult, :NovibeConsultPrompt, :NovibeProfile, :NovibeDistill, :NovibePromote user commands
```

## Core Flow

```
Visual select skeleton (or cursor on line)
  → input.lua float (vim.ui replacement, :w to submit)
  → prompt assembled: system_prompt + matched convention/learned sections
                    + treesitter enclosing signature (context.lua)
                    + ctx_before + selection + ctx_after
                    + LSP diagnostics for range (diag.lua)
                    + user instruction
  → fill-preview chat split opens immediately (chat.open_fill); focus stays on working buffer
  → provider streams stdout (stream-json events); stream.lua progressively decodes the "code" field
  → fill chat's push(partial) renders streamed code into the split (NOT the working buffer)
  → spinner virt_lines stay above/below the selection in the working buffer as a visual anchor
  → on stream completion: parse_output yields { code, message, changes, done }
  → finalize() splits the response into a "question queue":
       Q1   = in-scope code (if response.code is non-empty)
       Q2.. = each entry in response.changes (out-of-scope)
       total N = code + changes; user is shown exactly ONE question at a time
  → Each question renders the relevant content + "[k/N]" indicator in the winbar.
       in-scope code   → shown as raw code, "[k/N] In-scope code (will replace your selection):"
       out-of-scope    → shown as a find/replace diff, "[k/N] Out-of-scope: <file> [<action>]"
  → Per question the user can:
       · <CR>            → apply this question (splice code for code-Q, apply.lua for change-Q), advance
       · s               → skip this question (don't apply), advance
       · :w <text>       → revise via AI; prompt anchors the AI to the current head Q.
                           AI's response replaces the queue (new total = #code-Q + #changes).
                           Code-Q is only re-accepted if the current head was a code-Q.
       · :w all  /  :w * → apply every remaining question (in order) and close
       · q               → quit; previously-applied questions stay, remaining are dropped
  → When the queue is exhausted (or the user quits), the chat closes automatically.
```

### Multi-turn follow-up chat (M.open)

`M.open()` (the legacy split) is still available for cases where only out-of-scope changes are proposed without a fillable code field. It uses the same `<CR> apply` / `:w discuss` / `q quit` semantics plus `done:true` stays open until the user manually closes with `q`.

## Commands

- `:NovibeAct` — act on current line or explicit range (e.g. `:'<,'>NovibeAct`); input float accepts:
  - free-form instruction → fill/modify the selection in place
  - `#teach <reason>` → accumulate evidence for distillation (diff if editing a recent fill, otherwise a direct rule note)
  - `#gen <description>` → project-level generation: AI proposes new files via `changes[action=create]`, shown in the question queue for file-by-file review; no selection needed
- `:NovibeConsult` — open singleton interactive session in a vertical split; process is killed when buffer closes; `<Esc><Esc>` exits terminal mode; range `:'<,'>NovibeConsult` injects the selection. Seed includes: file, line, current git commit hash, matched `.no_vibe` sections (conventions, learned, and knowledge base), and snapshot instructions. Injected via `--append-system-prompt` for **claude**, `--prompt-interactive` for **gemini**. The AI may freely edit `CLAUDE.md` and all `.no_vibe/*.md` files; all other file modifications are off-limits. Say **"snapshot"** mid-session to have the AI write discoveries to the knowledge base. **opencode workaround:** no CLI flag exists, so use `:NovibeConsultPrompt` after the session is open — the seed is `chansend`-ed straight into opencode's input box; press Enter to submit.
- `:NovibeConsultPrompt` — build the consult seed from the current buffer/selection and chansend it into the active consult terminal. Required for opencode (which cannot receive context via CLI); also works with claude/gemini if you want to push fresh context mid-session. Must be invoked from the source buffer, not the consult terminal.
- `:NovibeProfile` — two-step picker: choose slot (Act / Consult), then profile. Each slot persists independently. No profile = CLI defaults.
- `:NovibeDistill` — distill accumulated diffs from `#teach` into topic-organized `.no_vibe/learned-*.md` files (Claude decides the topic split)
- `:NovibePromote` — review learned rules and graduate mature ones (support count n≥3) into canonical `.no_vibe/convention-*.md` files; opens the review split so changes can be inspected, revised, or skipped before applying

## CLI Invocation

**Claude provider (`provider = "claude"`):**
```lua
-- streaming (default — providers/claude.lua sets M.streaming = true):
{ claude_bin, "--continue", "--output-format", "stream-json", "--include-partial-messages", "--verbose", "--print", prompt }
-- non-streaming fallback:
{ claude_bin, "--continue", "--output-format", "json", "--print", prompt }
-- with active profile:
{ claude_bin, "--model", profile.model, "--effort", profile.effort, "--continue", ..., "--print", prompt }
-- with config.bare = true:
{ claude_bin, "--bare", ..., "--continue", ..., "--print", prompt }
```

`--continue` maintains session context across selections. `--bare` skips hooks, plugins, memory injection — only safe if auth is via `ANTHROPIC_API_KEY`, not `claude login`. `--model` and `--effort` are only added when an active profile is set. In streaming mode, `parse_chunk` extracts `content_block_delta` text-delta events and `parse_output` scans for the final `type=="result"` line.

**opencode provider (`provider = "opencode"`):**
```lua
{ opencode_bin, "run", "--format", "json", prompt }
-- with active profile:
{ opencode_bin, "run", "--format", "json", "--model", profile.model, "--variant", profile.effort, prompt }
-- with session continuity:
{ opencode_bin, "run", "--format", "json", "--session", session_id, prompt }
```

opencode has no `--continue`; session continuity is maintained by passing the `sessionID` returned in each response back as `--session` on the next call. `--variant` maps to opencode's effort levels. `--bare` is not applicable.

**gemini provider (`provider = "gemini"`):**
```lua
-- streaming (default — providers/gemini.lua sets M.streaming = true):
{ gemini_bin, "--output-format", "stream-json", "--prompt", prompt }
-- non-streaming fallback:
{ gemini_bin, "--output-format", "json", "--prompt", prompt }
-- with active profile:
{ gemini_bin, "--output-format", "stream-json", "--model", profile.model, "--prompt", prompt }
-- with session continuity:
{ gemini_bin, ..., "--session-id", session_id, "--prompt", prompt }
```

gemini has no `--continue`; session continuity uses `--session-id` with the UUID returned in the previous response's `session_id` field. No `--effort`/`--variant` equivalent. No `--bare`. The workspace must be trusted — run `gemini` interactively once and trust the directory, or set `GEMINI_CLI_TRUST_WORKSPACE=true`. In streaming mode, `parse_chunk` extracts assistant `delta=true` message events.

**`:NovibeConsult` (all providers):**
```lua
-- claude TUI:
{ claude_bin, "--append-system-prompt", seed }  -- + optional --model / --effort
-- opencode TUI:
{ opencode_bin }  -- no CLI flag for context seeding; user provides it manually
-- gemini TUI:
{ gemini_bin, "--prompt-interactive", seed }    -- + optional --model
```

## Profiles

User-defined in `setup()`. No defaults — must be explicit. No active profile = provider CLI chooses model and effort.

```lua
require("novibe").setup({
  profiles = {
    { label = "Claude Best",  provider = "claude",   model = "claude-opus-4-7",              effort = "max"  },
    { label = "Claude Fast",  provider = "claude",   model = "claude-haiku-4-5-20251001",    effort = "low"  },
    { label = "OC DeepSeek",  provider = "opencode", model = "opencode-go/deepseek-v4-pro",  effort = "high" },
    { label = "Gemini Flash", provider = "gemini",   model = "gemini-2.0-flash"                              },
  }
})
```

`provider`: `"claude"` (default), `"opencode"`, or `"gemini"`.
`effort` for claude: `low`, `medium`, `high`, `xhigh`, `max` (maps to `--effort`).
`effort` for opencode: maps to `--variant` (values depend on the model).
`effort` for gemini: ignored (no CLI flag equivalent).
`model` for claude: full ID (e.g. `claude-sonnet-4-6`) or alias (`sonnet`, `opus`).
`model` for opencode: `"provider/model"` format (e.g. `"opencode-go/deepseek-v4-pro"`). Run `opencode models` to list available options.
`model` for gemini: full ID (e.g. `gemini-2.0-flash`, `gemini-2.5-pro`). Run `gemini` and check `/model` in the TUI to see available options.

## JSON Response Schema

Claude always responds in this schema (enforced by system prompt):

```json
{
  "code": "modified selection only — spliced in place",
  "message": "question, explanation, or proposal summary (null if none)",
  "changes": [
    {
      "file": "relative/path/from/project/root",
      "description": "human-readable summary",
      "action": "replace | insert_after | insert_before",
      "find": "exact existing block to locate by content",
      "replace": "new code"
    }
  ],
  "done": true
}
```

`done: true` = apply changes immediately. `done: false` = open chat float for review.

## apply.lua: Content Matching

Never uses line numbers. Two-pass approach:
1. **Strict** — normalize (trim each line), match including blank lines
2. **Lenient** — match only non-empty lines, tolerate blank line count differences

`action` values:
- `replace` — find block, replace with new code
- `insert_after` — find anchor, insert new code after it
- `insert_before` — find anchor, insert new code before it
- `create` — write a brand-new file; `find` must be `""`. Errors if the file already exists.

## Convention, Learned Rule & Knowledge Base Files

Plugin walks up from `cwd` to find any of these, then filters all sections by current filename before appending to the prompt — AI never receives the full content, only matching sections. Both `:NovibeAct` and `:NovibeConsult` benefit from all layers.

Load order (concatenated in this order):
1. `NO_VIBE.md` at project root — single-file shortcut for simple projects, still supported
2. `.no_vibe/convention-*.md` (sorted) — human-written coding rules, split by topic
3. `.no_vibe/learned-*.md` (sorted) — auto-distilled by `:NovibeDistill` from `#teach` diffs
4. `.no_vibe/map-*.md` (sorted) — **dependency graph**: call chains, inheritance, who depends on what
5. `.no_vibe/rule-*.md` (sorted) — **behavioral constraints**: how to interact with each area (e.g. "always use Class X as db proxy")
6. `.no_vibe/decision-*.md` (sorted) — **architectural ADRs**: the why behind decisions and rejected alternatives

All files use the same section format:
```markdown
## always
rules that apply to every file

## src/db/**
knowledge about the db layer — loaded when working in src/db/

## *.tsx, *.jsx
rules for React components
```

Header is a comma-separated list of glob patterns (`*` = any non-separator, `**` = any path).
Special header `always` always loads regardless of filename.

### Knowledge Base: Stale Detection

`map-*`, `rule-*`, and `decision-*` sections support a `<!-- last-verified: HASH -->` comment that records the git commit when the knowledge was written:

```markdown
## src/db/**
<!-- last-verified: a3f9c2b -->
All db interactions go through Class X as proxy (src/db/proxy.ts).
Class Z extends Class K for auth-specific behavior.
```

When loading, `no_vibe.lua` runs `git log HASH..HEAD -- <path>` for directory-style section headers. If the area has new commits since the hash, the section is prefixed with `⚠ STALE: N commit(s) since HASH — verify before trusting.`

### Knowledge Base: Snapshot Workflow

Built exclusively during `:NovibeConsult`. Say **"snapshot"** whenever you discover something worth keeping — the AI writes it to the right file with the current commit hash. The knowledge base grows lazily as you explore the codebase, focused on areas you actually touch.

Three file types, each covering a different concern:
- `map-<area>.md` — structural: dependency chains, call graphs, inheritance
- `rule-<area>.md` — behavioral: constraints on how to interact with an area
- `decision-<area>.md` — reasoning: why something was built a certain way, what was rejected

Keep entries concise — the goal is a pointer to what matters, not a copy of the code.

## #teach / Distillation Flow

`#teach <reason>` accumulates evidence into `.no_vibe/diffs.json` in two modes:

- **Diff mode** — after a `:NovibeAct` fill, the user edits the result, re-selects, and runs `:NovibeAct` with `#teach <reason>`. The diff (original vs current selection) is captured.
- **Note mode** — `:NovibeAct` on any selection with `#teach <reason>` (no recent fill in this buffer required). The selection + reason is captured as a direct rule note, with no `original` field. Distillation treats both kinds as equally valid evidence.

The plugin picks the mode automatically: if `_last_fill` exists for the current buffer and the selection differs from the last fill's output, it's a diff; otherwise it's a note. Both require a non-empty reason if there's no diff to infer from.

Auto-distillation triggers when accumulated diffs reach the threshold:
- **1** if no `learned-*.md` files exist yet (fresh project — fast feedback)
- `learn.auto_extract_after` (default 3) once any learned file exists

`M.extract()` reads all existing `learned-*.md` files + new diffs, sends them to Claude with instructions to merge/dedupe and split by topic, then rewrites the affected files. Filenames must match `learned-[%w-]+%.md` for safety. Diffs are cleared after a successful distill.

## Key Lua APIs Used

- `vim.fn.getpos("'<")` / `vim.fn.getpos("'>")` — visual selection marks (after feedkeys Esc)
- `vim.api.nvim_buf_get_lines()` / `nvim_buf_set_lines()` — read/write buffer
- `vim.system(cmd, {text=true}, callback)` — async shell out (Neovim 0.10+)
- `vim.api.nvim_buf_set_extmark()` with `virt_lines` — inline spinner above/below selection
- `vim.uv.new_timer()` — spinner animation
- `vim.api.nvim_open_win()` — floating windows (input + chat)
- `vim.api.nvim_buf_add_highlight()` — diff colors in chat float
- `vim.bo[buf].buftype = "acwrite"` + `BufWriteCmd` autocmd — `:w` to submit floats
