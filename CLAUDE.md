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

`novibe.nvim` is a minimal Neovim plugin for LazyVim. The user writes function skeletons (signatures + descriptive comments), visually selects them, and invokes the plugin. The selection is sent to the active AI CLI (Claude Code, opencode, gemini, codex, or antigravity) and streamed into a **fill-preview chat split**. `<CR>` applies in-scope code, then any out-of-scope changes (imports, types, other files) are reviewed one at a time.

**Philosophy:** the user is the architect. AI fills boilerplate within user-defined boundaries; it never makes architectural decisions.

## File Structure

```
lua/novibe/
  init.lua     — entry: selection capture, prompt assembly, vim.system, streams to chat
  act2.lua     — :NovibeAct2: in-place fill with virt_line review controls (no chat window)
  gen.lua      — :NovibeGen: generate new files; pending list (one batch at a time);
                 each file opens as a real buffer with winbar + <C-f>/<leader>r/:w
  config.lua   — defaults: bare, system_prompt, profiles, learn.auto_extract_after, act2.keys
  input.lua    — floating input window (:w submits, <Esc> cancels; opts.initial pre-fills)
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
  providers/   — claude.lua, opencode.lua, gemini.lua, codex.lua, antigravity.lua: find_bin,
                 build_cmd, parse_output, parse_chunk, streaming
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

## Act2 Flow

`:NovibeAct2` is an alternative to `:NovibeAct` that avoids the chat window entirely. AI code is written directly into the buffer; a review bar appears as virt_lines above and below the scope.

```
Visual select → input.lua float (:w submit)
  → same prompt assembly as Act1 (system_prompt + conventions + ctx + diagnostics)
  → spinner virt_lines above/below selection while AI runs
  → on completion: parse_output → { code, message, changes, done }
  → if code is empty: vim.notify the message and exit
  → extmark anchors placed at selection start/end (track line shifts after splicing)

  Mode: "review"
  → virt_lines show: <CR> accept · U undo · <leader>r re-prompt · <leader>t teach
  → all keys are cursor-guarded: only fire when cursor is inside the scope
     (out-of-scope → feedkeys passes through to native vim behavior)

  <CR> accept:
    → splice ai_code into buffer (buf_set_lines on current extmark positions)
    → open out-of-scope scratch window (bottom split, non-focused) if changes[]
    → virt_lines shrink to: t teach this
    → Mode: "accepted"

  U undo (in "review"):
    → no splice happened — just clear extmarks and keymaps

  U undo (in "accepted"):
    → restore original_lines at current scope positions, clear state

  r re-prompt:
    → restore original_lines (no-op in review: nothing spliced yet)
    → clear state, call M.fill(sl, el, bufnr, last_prompt) — input float re-opens pre-filled

  t teach (two-phase):
    Phase 1 — press t in "review" or "accepted" mode:
      → if "review": also runs do_accept first (splice + show out-of-scope)
      → virt_lines change to: edit in scope · t done · U cancel
      → Mode: "teach"
      → user edits the AI code in-place; out-of-scope scratch stays open for reference

    U cancel (in "teach"):
      → mode → "accepted", virt_lines revert to: t teach this
      (user's edits stay; U only cancels teach intent, does not undo edits)

    Phase 2 — press t again in "teach" mode:
      → read current buffer lines in scope as `current`
      → teach_original (ai_code at accept time) is `original`
      → open input float (empty) for reason text
      → on submit: learn.teach(original≠current ? original : nil, current, reason, …)
      → clear state

  queue exhausted or quit → extmarks and keymaps cleaned up
  BufWipeout autocmd ensures cleanup even if buffer is force-closed
```

### Act2: session continuity

Act2 always passes `use_continue = false`. Each fill is a fresh session — no `_session_id` is tracked or reused. Keeps Act2 fast and context-clean at the cost of session memory.

### Act2: token guard

`M.fill` captures `local token = {}` before `vim.system`. If the user triggers a second fill before the first AI response arrives, `clear_state` runs on the old state and the callback checks `_states[bufnr].token == token` before writing — stale callbacks are silently discarded.

## Commands

- `:NovibeAct` — act on current line or range. Input float accepts:
  - free-form instruction → fill/modify the selection
  - `#teach <reason>` → accumulate evidence (diff if editing a recent fill, else note)
- `:NovibeGen` — generate new files from a description. Empty pending → input prompt → AI generates → populate pending list. Non-empty pending → show picker (one batch at a time). Each file opens as a real listed buffer named with the proposed path; winbar shows path + keys. `<C-f>` opens input float pre-filled with current path to change it. `<leader>r` re-prompts pre-filled with last description. `:w` saves to the path in the buffer name. `BufWritePost`/`BufWipeout` remove entry from pending. No `apply.lua` — user saves manually. Single proposed file → opens directly; multiple → picker first.
- `:NovibeAct2` — alternative no-chat-window fill. AI code is written directly into the buffer; virt_lines above/below the scope show review controls (`<CR>` accept, `U` undo, `<leader>r` re-prompt, `<leader>t` teach). Keys are cursor-guarded (only fire when cursor is inside scope). Out-of-scope changes shown in a non-focused bottom scratch window. Two-phase `<leader>t` teach: first press accepts + enters edit mode, second press captures the diff and opens a reason float. Session is always fresh (no `--continue`). All keys configurable via `setup({ act2 = { keys = {...} } })`.
- `:NovibeConsult` — singleton interactive session in a vsplit. Process dies with buffer; `<Esc><Esc>` exits terminal mode; range injects selection. Seed = file, line, current commit hash, matched `.no_vibe` sections, snapshot instructions. Injected via `--append-system-prompt` (claude) or `--prompt-interactive` (gemini). AI may freely edit `CLAUDE.md` and `.no_vibe/*.md`; all other files off-limits. Say **"snapshot"** mid-session to persist discoveries. **opencode workaround:** no flag exists, so use `:NovibeConsultPrompt` after opening — the seed is `chansend`-ed into the input box; press Enter to submit.
- `:NovibeConsultPrompt` — build the consult seed from current buffer/selection and chansend it into the active consult terminal. Required for opencode; optional refresh for claude/gemini/codex. Invoke from the source buffer, not the consult terminal.
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

**codex** (`provider = "codex"`):
```lua
-- fresh session:
{ codex_bin, "exec", "--json", "--sandbox", "read-only",
  "-c", 'instructions="<toml-escaped system prompt>"', prompt }
-- resume (session_id = thread_id from previous thread.started event):
{ codex_bin, "exec", "resume", session_id, "--json",
  "-c", 'instructions="<toml-escaped system prompt>"', prompt }
-- + "-m", profile.model   (when profile active; no effort equivalent)
```
Non-streaming: all JSONL events arrive at once. `parse_output` finds the `item.completed` event with `item.type=="agent_message"` for the response text; `thread.started` carries the `thread_id` used as `session_id`. System prompt is injected via `-c instructions="..."` (TOML-escaped). Codex is instructed not to run shell commands so it responds immediately with JSON.

**antigravity** (`provider = "antigravity"`):
```lua
-- fresh session:
{ agy_bin, "--print", prompt }
-- resume (session_id sentinel "__continue__" signals prior exchange exists):
{ agy_bin, "--continue", "--print", prompt }
```
Non-streaming: stdout is the raw AI response text (no JSON wrapper). `parse_output` parses it directly as JSON. No `--model`, `--effort`, `--bare`, or system-prompt flags. System prompt is prepended to the user prompt inside `<instructions>` tags (no CLI injection). Session continuity uses `--continue` (resumes the most recent conversation for the cwd); `parse_output` always returns `session_id = "__continue__"` as a sentinel to trigger `--continue` on subsequent calls.

**`:NovibeConsult` (TUI mode):**
```lua
{ claude_bin,   "--append-system-prompt", seed }  -- + optional --model / --effort
{ opencode_bin }                                   -- no seed flag; use NovibeConsultPrompt
{ gemini_bin,   "--prompt-interactive",   seed }  -- + optional --model
{ codex_bin,    seed }                             -- seed as initial prompt positional arg
{ agy_bin,      "--prompt-interactive",   seed }  -- no --model flag
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
    { label = "Codex o4",     provider = "codex",       model = "o4-mini"                                      },
    { label = "Antigravity",  provider = "antigravity"                                                          },
  }
})
```

- `provider`: `"claude"` (default) | `"opencode"` | `"gemini"` | `"codex"` | `"antigravity"`
- `effort` (claude): `low`/`medium`/`high`/`xhigh`/`max` → `--effort`
- `effort` (opencode): maps to `--variant` (values depend on model)
- `effort` (codex): maps to `-c model_reasoning_effort=<value>`; `max` → `xhigh`; values: `minimal|low|medium|high|xhigh`
- `effort` (gemini): ignored (no CLI flag equivalent)
- `effort` (antigravity): ignored (no CLI flag equivalent)
- `model` (claude): full ID (`claude-sonnet-4-6`) or alias (`sonnet`, `opus`)
- `model` (opencode): `"provider/model"` (run `opencode models`)
- `model` (gemini): full ID (run `gemini`, check `/model` in TUI)
- `model` (codex): model ID (e.g. `o4-mini`, `o3`); run `codex` and check available models
- `model` (antigravity): ignored (no `--model` CLI flag; set model via `agy` settings)

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
- **Act2 integrated mode** — press `t` (default) inside an active `:NovibeAct2` scope. Phase 1 accepts the code and enters edit mode (virt_lines show "edit in scope · t done"); phase 2 opens a reason float and calls `learn.teach(ai_code, current_in_scope, reason, …)`. `original` is the AI's output; `current` is whatever the user edited it to. If unedited, saves as a note. No re-selection required — scope is tracked by extmarks.

`:NovibeAct` picks diff vs note automatically: diff if `_last_fill` exists for the buffer and the selection differs from the last fill's output; otherwise note. Both require a non-empty reason if there's no diff to infer from.

Auto-distillation threshold:
- **1** when no `learned-*.md` exists yet (fresh project — fast feedback)
- `learn.auto_extract_after` (default 3) once any learned file exists

`M.extract()` sends accumulated diffs + existing `learned-*.md` to the AI to merge/dedupe and split by topic. Filenames must match `learned-[%w-]+%.md`. Diffs are cleared on success.
