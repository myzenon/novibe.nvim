# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Plugin Does

`novibe.nvim` is a minimal Neovim plugin for LazyVim. The user writes function skeletons — signatures plus descriptive comments — visually selects the block, and invokes the plugin. The selection is sent to the active AI CLI (Claude Code or opencode) and replaced in-place with the filled implementation. Out-of-scope changes (imports, types, other files) are proposed in a multi-turn chat float for review before applying.

**Philosophy:** the user is the architect. Claude fills boilerplate within boundaries the user defined. AI never makes architectural decisions.

## File Structure

```
lua/novibe/
  init.lua     — entry point: selection capture, prompt assembly, vim.system call, JSON dispatch
  config.lua   — defaults: bare flag, system_prompt, profiles, learn.auto_extract_after
  input.lua    — floating input window (:w submits, <Esc> cancels)
  chat.lua     — multi-turn follow-up float: renders diff proposals, local confirm, schema reminder
  apply.lua    — content-based find-and-replace across files (two-pass: strict then lenient)
  glob.lua     — glob → Lua pattern conversion + section header matching
  no_vibe.lua  — loads NO_VIBE.md + .no_vibe/convention-*.md + .no_vibe/learned-*.md, filters by filename
  learn.lua    — #teach diff capture (.no_vibe/diffs.json) + distillation into learned-*.md topic files
  consult.lua  — singleton interactive consult: opens in current window, seeds file/line/selection/conventions; supports claude and opencode TUI
plugin/
  novibe.lua   — guard + :NovibeAct, :NovibeConsult, :NovibeProfile, :NovibeDistill user commands
```

## Core Flow

```
Visual select skeleton (or cursor on line)
  → input.lua float (vim.ui replacement, :w to submit)
  → prompt assembled: system_prompt + matched convention/learned sections + context + selection + instruction
  → claude [--model X] [--effort Y] --continue --print "prompt"   (claude provider)
  → opencode run [--model X] [--variant Y] [--session ID] "prompt" (opencode provider)
  → JSON response parsed
  → response.code spliced into buffer immediately
  → if response.message or response.changes → chat.lua float opens
  → chat: confirm with "ok/yes/apply" (local, no round-trip) or free-form reply (:w to send)
  → on confirm: apply.lua applies each change to target files
```

## Commands

- `:NovibeAct` — act on current line or explicit range (e.g. `:'<,'>NovibeAct`); input float accepts free-form instruction, or `#teach <reason>` to accumulate evidence (diff if editing a recent fill, otherwise a direct rule note)
- `:NovibeConsult` — open singleton interactive session in a vertical split; process is killed when buffer closes; `<Esc><Esc>` exits terminal mode; range `:'<,'>NovibeConsult` injects the selection. Context (file, line, selection, matched `.no_vibe` sections, novibe format explanation, consult-only enforcement) is injected via `--append-system-prompt` for **claude**, `--prompt-interactive` for **gemini**. **opencode limitation:** no equivalent CLI flag exists — context cannot be injected; user must provide it manually.
- `:NovibeProfile` — two-step picker: choose slot (Act / Consult), then profile. Each slot persists independently. No profile = CLI defaults.
- `:NovibeDistill` — distill accumulated diffs from `#teach` into topic-organized `.no_vibe/learned-*.md` files (Claude decides the topic split)

## CLI Invocation

**Claude provider (`provider = "claude"`):**
```lua
{ claude_bin, "--continue", "--print", prompt }
-- with active profile:
{ claude_bin, "--model", profile.model, "--effort", profile.effort, "--continue", "--print", prompt }
-- with config.bare = true:
{ claude_bin, "--bare", ..., "--continue", "--print", prompt }
```

`--continue` maintains session context across selections. `--bare` skips hooks, plugins, memory injection — only safe if auth is via `ANTHROPIC_API_KEY`, not `claude login`. `--model` and `--effort` are only added when an active profile is set.

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
{ gemini_bin, "--output-format", "json", "--prompt", prompt }
-- with active profile:
{ gemini_bin, "--output-format", "json", "--model", profile.model, "--prompt", prompt }
-- with session continuity:
{ gemini_bin, "--output-format", "json", "--session-id", session_id, "--prompt", prompt }
```

gemini has no `--continue`; session continuity uses `--session-id` with the UUID returned in the previous response's `session_id` field. No `--effort`/`--variant` equivalent. No `--bare`. The workspace must be trusted — run `gemini` interactively once and trust the directory, or set `GEMINI_CLI_TRUST_WORKSPACE=true`.

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

## Convention & Learned Rule Files

Three sources of project rules. Plugin walks up from `cwd` to find any of them, then filters all sections by current filename before appending to the prompt — Claude never receives the full content, only matching sections.

Load order (concatenated in this order):
1. `NO_VIBE.md` at project root — single-file shortcut for simple projects, still supported
2. `.no_vibe/convention-*.md` (sorted) — human-written. Any number of files, named freely after the `convention-` prefix. Users split however suits the project (topic, layer, ownership — their call).
3. `.no_vibe/learned-*.md` (sorted) — auto-distilled by `:NovibeDistill` from `#teach` diffs; topic split decided by Claude (`learned-style.md`, `learned-react.md`, etc.)

All files use the same section format:
```markdown
## always
rules that apply to every file

## *.tsx, *.jsx
rules for React components

## use*.ts
rules for React hooks
```

Header is a comma-separated list of glob patterns (`*` = any non-separator, `**` = any path).
Special header `always` always loads regardless of filename.

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
