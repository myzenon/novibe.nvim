# novibe.nvim — Configuration

Detailed reference for profiles, conventions, opencode integration, and `setup()` options. For installation and basic usage, see [README.md](../README.md).

---

## Table of contents

- [Fresh project setup](#fresh-project-setup)
  - [Setup modes](#setup-modes)
- [Profiles](#profiles)
- [Provider differences](#provider-differences)
- [Conventions](#conventions)
- [Configuration reference](#configuration-reference)
- [Statusline integration](#statusline-integration)
- [How it works](#how-it-works)

---

## Fresh project setup

The fastest way to bootstrap conventions is to ask your AI CLI to do it:

**Claude Code:**
1. Open a terminal in your project root: `claude`
2. Paste: `"Read https://raw.githubusercontent.com/myzenon/novibe.nvim/main/docs/claude-init.md and follow the instructions."`

**opencode:**
1. Open a terminal in your project root: `opencode`
2. Paste: `"Read https://raw.githubusercontent.com/myzenon/novibe.nvim/main/docs/opencode-init.md and follow the instructions."`

**OpenAI Codex:**
1. Open a terminal in your project root: `codex`
2. Paste: `"Read https://raw.githubusercontent.com/myzenon/novibe.nvim/main/docs/codex-init.md and follow the instructions."`

The agent asks two questions, then generates the initial `topics/` knowledge base. The init is safe to re-run as the project grows — it expands and merges, never overwrites.

### Setup modes

**Hybrid** — the novibe format spec is appended to `CLAUDE.md` / `AGENTS.md` so the AI CLI knows about `.no_vibe/` in all sessions, including interactive ones outside of novibe fills. Best when you already use these files for project conventions or want the whole team to benefit.

**Pure novibe** — no instruction files needed. `.no_vibe/topics/` is the single source of truth; novibe injects context at fill time. Any existing team `CLAUDE.md` / `AGENTS.md` handles base CLI behavior only. Best for personal setups or projects where you don't want to touch shared instruction files.

You can add more topic folders at any time — just update `topics/index.md` to register them.

---

## Profiles

Profiles combine a provider, model, and effort level into a named preset. Define them yourself — there are no built-in defaults. Mix providers freely.

```lua
require("novibe").setup({
  profiles = {
    -- Claude Code CLI
    { label = "Fast",     provider = "claude", model = "claude-haiku-4-5-20251001", effort = "low" },
    { label = "Balanced", provider = "claude", model = "claude-sonnet-4-6",         effort = "medium" },
    { label = "Best",     provider = "claude", model = "claude-opus-4-7",           effort = "max" },

    -- opencode (model uses "provider/model" format; effort maps to --variant)
    { label = "OC Sonnet", provider = "opencode", model = "anthropic/claude-sonnet-4-5", effort = "high" },
    { label = "OC GPT-5",  provider = "opencode", model = "openai/gpt-5",                effort = "medium" },

    -- OpenAI Codex (effort maps to model_reasoning_effort config key)
    { label = "Codex o4-mini", provider = "codex", model = "o4-mini", effort = "high" },
    { label = "Codex o3",      provider = "codex", model = "o3",      effort = "xhigh" },
  },
})
```

Switching profiles via `:NovibeProfile` swaps everything atomically. LazyVim with lua-language-server gives autocomplete on the `provider` field, so you won't mistype.

### Fields

**`provider`** — `"claude"` (default if omitted), `"opencode"`, `"codex"`, or `"antigravity"`.

**`model`** — full model ID or alias accepted by the active provider's CLI.

For **Claude**:

| Alias | Full ID |
|---|---|
| `haiku` | `claude-haiku-4-5-20251001` |
| `sonnet` | `claude-sonnet-4-6` |
| `opus` | `claude-opus-4-7` |

For **opencode**: use `provider/model` format. Run `opencode models` to list everything available, e.g. `anthropic/claude-sonnet-4-5`, `openai/gpt-5`, `google/gemini-2.5-pro`.

For **Codex**: model ID, e.g. `o4-mini`, `o3`. Check available models in an interactive `codex` session.

**`file_context`** — `true` injects sibling files (same directory) and parsed imports from the current buffer into the prompt as a "Project files" list. The model is instructed to only reference these paths in `changes[]`. Defaults to `false`.

Recommended for cheaper / less reliable models that tend to hallucinate file paths (e.g. inventing `src/components/X.tsx` when a component is actually inline). Disable for Claude Opus / Sonnet — they generally don't need it and you save tokens.

```lua
{ label = "OC GPT-5", provider = "opencode", model = "openai/gpt-5", effort = "high", file_context = true }
```

**`effort`** — Claude maps to `--effort`, opencode maps to `--variant`, Codex maps to `-c model_reasoning_effort=<value>`. Antigravity has no equivalent and ignores this field.

| Level | Notes |
|---|---|
| `low` | Fastest, least reasoning |
| `medium` | Default |
| `high` | More reasoning, slower |
| `xhigh` | Deeper reasoning — **Opus 4.7 only** on Claude |
| `max` | Maximum reasoning |

> The Claude CLI documents `xhigh` as Opus-only. Other levels may have model restrictions — check `/effort` inside an interactive `claude` session. opencode's `--variant` accepts the same level names but support depends on the model.

---

## Provider differences

All providers are first-class. novibe normalizes most of the differences (session continuity, JSON output, usage stats), but a few CLI quirks surface in the UI. Knowing them helps you read the status line and pick the right `effort` level.

### Claude Code

- **Session continuity**: first fill uses `--continue` (most recent session); subsequent fills use `--resume <session_id>` (precise UUID extracted from the response). `:NovibeReset` skips continuity on the next fill.
- **`--bare`** mode is supported (set `bare = true` in `setup()` if you auth via `ANTHROPIC_API_KEY`).
- **Context window %** is reported by the CLI and shown in the input title / chat winbar / lualine.
- **`--effort`** levels: `low`, `medium`, `high`, `xhigh` (Opus only), `max`.

### opencode

- **Sessions**: novibe captures the `sessionID` from the first response and reuses it via `--session ID` for follow-up fills. Mirrors Claude's `--continue` UX. `:NovibeReset` clears it.
- **`bare` mode**: silently ignored — it's a Claude-specific flag.
- **Context window %**: not shown — the opencode CLI doesn't expose context window size. Cost and token counts still display.
- **`--variant`** maps from `effort`. Same level names, but support depends on the model.
- **Tools / default agent**: opencode's default `build` agent has tool access. novibe's strict JSON system prompt usually keeps the model from invoking tools, but if you see file edits happening outside the review flow, configure a no-tools agent (see `opencode agent`) and reference it as your default.
- **Hallucinated paths**: cheaper models on opencode are more prone to inventing file paths in `changes[]`. Set `file_context = true` on the profile to inject a "Project files" allow-list — see [Profiles → fields](#fields).

### OpenAI Codex

- **Sessions**: novibe captures `thread_id` from the first response and reuses it via `codex exec resume <thread_id>` for follow-up fills. `:NovibeReset` clears it.
- **Non-streaming**: unlike the other providers, codex delivers all output at once (no streaming). The fill-preview split won't animate — it appears complete when the response arrives.
- **`bare` mode**: silently ignored — Claude-only.
- **`effort`**: maps to `-c model_reasoning_effort=<value>`. Values: `minimal`, `low`, `medium`, `high`, `xhigh`; `max` maps to `xhigh`. Only effective on reasoning models (o-series).
- **System prompt**: novibe injects its JSON schema instructions via codex's `-c instructions="..."` config override, which replaces codex's built-in system prompt. This keeps codex focused on JSON output instead of its default agentic behavior.
- **Shell commands**: codex is an agentic tool and may try to run shell commands before answering. novibe instructs it not to, which keeps responses fast. If you see `item.command_execution` events in debug output, the instruction was overridden by the model — simplify the prompt or try a different model.
- **Cost**: not reported by the CLI.
- **Context window %**: not exposed.
- **Consult**: seed is passed as the initial prompt positional argument (`codex "seed"`), which starts the interactive TUI with context pre-loaded.

### Antigravity

- **Sessions**: `--continue` resumes the most recent conversation for the cwd. novibe passes it on every fill after the first. `:NovibeReset` skips it.
- **Non-streaming**: stdout is raw AI response text (no JSON wrapper). Fill-preview split appears complete when the response arrives.
- **`bare` / `effort`**: no equivalent — both ignored.
- **Model**: set via `--model "<display name>"` (run `agy models` to list). Note: `agy` is a compiled binary — if `agy --help` shows a shell script header, you have the desktop editor wrapper instead of the CLI.
- **System prompt**: prepended to the user prompt inside `<instructions>` tags (no CLI injection flag).
- **Consult**: context injected via `--prompt-interactive` (starts interactive session with seed pre-submitted).
- **Cost / context window %**: not reported by the CLI.

---

## Conventions

novibe loads knowledge from `.no_vibe/` in this order:

1. `NO_VIBE.md` at project root — optional single-file shortcut for simple projects
2. `.no_vibe/config.md` — personal config, filtered by mode (`## Always`, `## Act`, `## Agent`)
3. `topics/index.md` → matched topic folders → `topics/<area>/rule.md`
4. `.no_vibe/act/learned-*.md` — auto-distilled from `#teach` (act mode only, don't edit by hand)

Example layout:

```
NO_VIBE.md                      ← optional single-file shortcut
.no_vibe/
  config.md                     ← personal config (gitignore this)
  topics/
    index.md                    ← routing: area names + globs
    global/
      rule.md                   ← always-loaded global rules
    react/
      rule.md                   ← rules for React files
      doc.md                    ← how the React layer works (agent on-demand)
      why.md                    ← architectural decisions (agent on-demand)
    db/
      rule.md                   ← db interaction rules
  act/
    learned-style.md            ← auto-distilled (don't edit)
    learned-react.md            ← auto-distilled (don't edit)
  diffs.json                    ← transient working state (gitignore this)
```

### topics/index.md

Routes filenames to topic folders. Only matching topics are loaded — nothing leaks across file types.

```markdown
## Always
Rules and docs that load for every file.
- topics/global/

## React [*.tsx, *.jsx]
React component conventions.
- topics/react/

## Database [src/db/**]
All database interaction goes through the proxy layer.
- topics/db/
```

- `## Always` — loads for every file
- `## Name [glob]` — loads when the current file matches the glob (comma-separated patterns allowed)
- `*` matches within a segment, `**` matches across separators

### topics/\<area\>/rule.md

The behavioral rules for that area. Loaded whole when the index matches — no section filtering. Write directives only, no prose.

```markdown
- ES6 named imports only — no default imports from libraries
- TypeScript: explicit types on all function parameters and return values
- No console.log in filled code

## *.tsx, *.jsx
- UI library: MUI only — never introduce other UI libraries
- Styling: MUI sx prop only — never style={{}} inline objects
```

Rule files can optionally use glob-section headers internally if needed (same `## glob` format), but most topic rule files are flat — the index already scoped them.

### config.md

Personal preferences that don't belong in shared project knowledge. Filtered by command:
- `:NovibeAct` / `:NovibeAct2` → `## Always` + `## Act`
- `:NovibeAgent` / `:NovibeConsult` → `## Always` + `## Agent`

Seed it with your personal config seeder (see `examples/my-novibe-config-seeder.md` in the novibe.nvim repo). Gitignore it if it contains personal preferences you don't want committed.

### Adding global conventions across all projects

For rules that apply to every project regardless of codebase, append them to the system prompt:

```lua
require("novibe").setup({
  system_prompt = require("novibe.config").defaults.system_prompt .. [[

Personal conventions (always apply):
- Prefer early returns over nested conditionals
- No magic numbers: extract constants with descriptive names
]],
})

---

## Configuration reference

```lua
require("novibe").setup({
  -- No keymap default — define it in lazy.nvim's keys spec (see README)

  bare = false,
  -- true = --bare flag (claude only; faster, skips plugins/hooks/memory)
  -- requires ANTHROPIC_API_KEY auth, not claude login. Ignored on opencode.

  profiles = {},
  -- No defaults — define your own (see Profiles above)
  -- No active profile = CLI picks model and effort

  learn = {
    auto_extract_after = 3,
    -- Number of #teach diffs that triggers automatic distillation.
    -- On a fresh project (no act/learned-*.md yet) the threshold is forced to 1
    -- for fast feedback, regardless of this value.
    -- Set to nil to disable auto-distillation (use :NovibeDistill manually).
    -- See docs/teach.md for the full teach → distill → promote lifecycle.
  },

  act2 = {
    -- Buffer-local review keys for :NovibeAct2.
    -- All keys are cursor-guarded: they only fire when the cursor is inside the
    -- active fill scope. Outside the scope, native vim behavior is restored.
    -- Override any key that conflicts with your vim motion bindings.
    keys = {
      accept   = "<CR>",       -- splice AI code, open out-of-scope scratch (non-focused)
      undo     = "U",          -- restore original lines and dismiss (or cancel teach mode)
      reprompt = "<leader>r",  -- restore original and reopen input float pre-filled
      teach    = "<leader>t",  -- two-phase teach: first press enters edit mode, second captures diff
    },
  },

  system_prompt = "...",
  -- Override the default system prompt entirely, or append to it:
  -- require("novibe.config").defaults.system_prompt .. "\nyour additions"
})
```

---

## Statusline integration

Cost and context % show automatically in the input dialog title and chat winbar. For persistent display in the statusline, add a lualine component:

```lua
-- in your lualine setup
lualine_x = {
  { require("novibe").statusline },
  -- ... your other components
}
```

The component returns `" $0.0039 · ctx 6%"` after a fill, or empty string when there's no recent usage data.

---

## How it works

```
Write skeleton → visual select → <leader>aa  (or #gen for new files)
                                      ↓
                              floating input prompt
                                      ↓ :w
                    system_prompt + matched convention/learned/knowledge sections
                  + treesitter enclosing function/class signature
                  + 10 lines context above/below selection
                  + LSP diagnostics for the selection range
                  + your instruction
                                      ↓
          provider.build_cmd() → claude / opencode  (streaming)
                                   codex / antigravity (non-streaming)
                                      ↓
              fill-preview split opens immediately (right vsplit, no focus steal)
              partial code streams into the split as chunks arrive
                                      ↓
                        stream complete → question queue built
               ┌─────────────────────────────────────────────┐
               │  [1/N] in-scope code                        │
               │        <CR> splices into your buffer        │
               │  [2/N] out-of-scope: path/to/file [action]  │
               │        <CR> applies via content matching    │
               │  ...                                        │
               │  <CR> apply · s skip · :w feedback · q quit │
               └─────────────────────────────────────────────┘
```

The model responds in a structured JSON schema (`{code, message, changes, done}`). `response.code` is the in-scope fill (your selection replaced). `response.changes` is a list of out-of-scope edits — each shown as a diff with the file path and action (`replace`, `insert_after`, `insert_before`, `create`, `delete`) in the header. Everything goes through the review queue; nothing is written or deleted until you press `<CR>`.

**Hallucinated paths** are flagged inline in the queue with a `⚠` warning so you can revise the path with `:w` or skip with `s` before wasting a confirm. Combined with `file_context = true` in your profile, hallucinated paths become rare.
