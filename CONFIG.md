# novibe.nvim — Configuration

Detailed reference for profiles, conventions, opencode integration, and `setup()` options. For installation and basic usage, see [README.md](./README.md).

---

## Table of contents

- [Fresh project setup](#fresh-project-setup)
- [Profiles](#profiles)
- [Provider differences](#provider-differences)
- [Conventions](#conventions)
- [Promotion](#promotion)
- [Configuration reference](#configuration-reference)
- [Statusline integration](#statusline-integration)
- [How it works](#how-it-works)

---

## Fresh project setup

The fastest way to bootstrap conventions is to ask your AI CLI to do it:

**Claude Code:**
1. Open a terminal in your project root: `claude`
2. Paste: `"Read https://raw.githubusercontent.com/myzenon/novibe.nvim/main/claude-init.md and follow the instructions."`
3. The agent generates `.no_vibe/convention-project.md` and appends the novibe format spec to `CLAUDE.md` so it auto-loads in every future Claude Code session.

**opencode:**
1. Open a terminal in your project root: `opencode`
2. Paste: `"Read https://raw.githubusercontent.com/myzenon/novibe.nvim/main/opencode-init.md and follow the instructions."`
3. The agent generates `.no_vibe/convention-project.md` and appends the novibe format spec to `AGENTS.md`.

You can add more `convention-*.md` files later (`convention-frontend.md`, `convention-style.md`, etc.). All matching files are loaded and merged.

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
  },
})
```

Switching profiles via `:NovibeProfile` swaps everything atomically. LazyVim with lua-language-server gives autocomplete on the `provider` field, so you won't mistype.

### Fields

**`provider`** — `"claude"` (default if omitted) or `"opencode"`.

**`model`** — full model ID or alias accepted by the active provider's CLI.

For **Claude**:

| Alias | Full ID |
|---|---|
| `haiku` | `claude-haiku-4-5-20251001` |
| `sonnet` | `claude-sonnet-4-6` |
| `opus` | `claude-opus-4-7` |

For **opencode**: use `provider/model` format. Run `opencode models` to list everything available, e.g. `anthropic/claude-sonnet-4-5`, `openai/gpt-5`, `google/gemini-2.5-pro`.

**`file_context`** — `true` injects sibling files (same directory) and parsed imports from the current buffer into the prompt as a "Project files" list. The model is instructed to only reference these paths in `changes[]`. Defaults to `false`.

Recommended for cheaper / less reliable models that tend to hallucinate file paths (e.g. inventing `src/components/X.tsx` when a component is actually inline). Disable for Claude Opus / Sonnet — they generally don't need it and you save tokens.

```lua
{ label = "OC GPT-5", provider = "opencode", model = "openai/gpt-5", effort = "high", file_context = true }
```

**`effort`** — Claude maps to `--effort`, opencode maps to `--variant`:

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

Both providers are first-class. novibe normalizes most of the differences (session continuity, JSON output, usage stats), but a few CLI quirks surface in the UI. Knowing them helps you read the status line and pick the right `effort` level.

### Claude Code

- **`--continue`** is used to carry session context across fills. `:NovibeReset` skips it on the next fill.
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

---

## Conventions

novibe loads rules from these sources (in order):

1. `NO_VIBE.md` at project root — optional single-file shortcut
2. `.no_vibe/convention-*.md` — human-written rules. Any number of files, named freely after `convention-`. Split however suits you (by topic, layer, ownership).
3. `.no_vibe/learned-*.md` — auto-distilled from `#teach` (don't edit by hand)

Example layout:

```
NO_VIBE.md                ← optional single-file shortcut
.no_vibe/
  convention-project.md   ← e.g. project-wide rules
  convention-frontend.md  ← e.g. split by topic
  convention-me.md        ← e.g. personal preferences (gitignore this)
  learned-style.md        ← auto-distilled (don't edit)
  learned-react.md        ← auto-distilled (don't edit)
  diffs.json              ← transient working state (gitignore this)
```

Only the `## always` section + sections matching the current filename are sent to the model — nothing leaks across file types.

### Format

All rule files use the same section format:

```markdown
## always
Rules that apply to every file in this project, regardless of type.

## *.tsx, *.jsx
Rules that apply only when filling React component files.

## use*.ts, *.hook.ts
Rules for React hook files.

## *.api.ts, *.service.ts
Rules for API/service layer files.

## **/tests/**, *.test.ts, *.spec.ts
Rules for test files.
```

**Section headers** are comma-separated glob patterns:
- `*` matches anything except a path separator
- `**` matches anything including path separators
- `always` is a special header that always loads

A hooks file never sees CSS conventions. A component file never sees backend rules.

### Example `.no_vibe/convention-project.md`

```markdown
## always
- ES6 named imports only — no default imports from libraries
- TypeScript: explicit types on all function parameters and return values
- No console.log, no TODO comments left in filled code
- Error handling: never swallow errors silently

## *.tsx, *.jsx
- UI library: MUI only (@mui/material) — never introduce other UI libraries
- Never use native HTML elements where MUI has an equivalent (use Box not div, Typography not p)
- Styling: MUI sx prop only — never style={{}} inline objects
- Components: functional only, no class components
- Props: always define a typed Props interface above the component

## use*.ts, *.hook.ts
- Return plain values and functions — no JSX
- Always clean up subscriptions and timers: return a cleanup function from useEffect
- No direct API calls — use service layer functions

## *.api.ts, *.service.ts
- HTTP client: axios only — never fetch
- Always handle errors explicitly, never return undefined on failure
- Return typed responses — no any

## *.test.ts, *.spec.ts, *.test.tsx
- Testing library: Vitest + React Testing Library
- No implementation detail testing — test behavior, not internals
- Mock at the boundary: mock HTTP calls, not internal functions
```

### Generating rules with AI

Paste this prompt into your AI of choice (Claude Code, opencode, ChatGPT, etc.):

> I want you to generate a `.no_vibe/convention-project.md` file for my project. This file tells an AI code-filling tool which conventions to follow when filling in code.
>
> **Format rules:**
> - Use `## always` for rules that apply to every file
> - Use `## *.ext` headers (glob patterns) for file-type-specific rules
> - Multiple patterns per header are comma-separated: `## *.tsx, *.jsx`
> - Rules should be short, directive, and unambiguous — one rule per line starting with `-`
> - Do NOT explain why, do NOT add prose — only rules the AI must follow
> - Rules should be constraints on what to use/not use, not general advice
>
> **My project:**
> [describe your stack, libraries, patterns, and anything the AI should always or never do]
>
> Generate the file now.

**Tips for good rules:**
- **Be specific about libraries**: "MUI only" not "use a UI library"
- **Name what to avoid**: "never style={{}}" beats "prefer sx prop"
- **One decision per rule**: don't combine multiple constraints in one line
- **File-type rules should be truly file-type specific** — if it applies everywhere, put it in `always`

---

## Promotion

`learned-*.md` is a **staging area** — AI's hypothesis about your style based on observed `#teach` diffs. Mutable, regenerated by future distillations.
`convention-*.md` is **canonical** — rules you've committed to. Stable. Distillation never touches them.

Promotion graduates a learned rule from staging to canonical.

### Support counts

Every rule in `learned-*.md` carries an HTML-comment support count:

```markdown
## always
- prefer for-loops over .map() <!-- n=8 -->
- always use early return <!-- n=4 -->
- no semicolons <!-- n=1 -->
```

`n` = the number of distinct `#teach` diffs that reinforce this rule. The distillation prompt preserves and increments this counter as new diffs arrive.

**Rule of thumb:** `n >= 3` → mature, ready to consider promoting. `n == 1` → premature, leave it staged.

### `:NovibePromote`

Run the command. The plugin reads all `learned-*.md` and existing `convention-*.md` files, asks the model to identify mature rules and propose where they should land, then opens the same chat side panel you use for out-of-scope changes:

```
I propose promoting 3 stable rules to conventions:

[1/3] .no_vibe/convention-style.md  [new file]
│  Mature style rules graduated from learned-style.md
│
  + ## always
  + - prefer for-loops over .map()
  + - always use early return
└──────────────────────────────────────────

[2/3] .no_vibe/learned-style.md  [replace]
│  Remove promoted rules; keep premature ones
│
  - prefer for-loops over .map() <!-- n=8 -->
  - always use early return <!-- n=4 -->
  + (only "no semicolons <!-- n=1 -->" remains)
└──────────────────────────────────────────
```

Then you interact exactly like the out-of-scope review:

- `ok` / `yes` / `lgtm` + `:w` — apply all changes (creates convention files, prunes learned files)
- `"put style rules in convention-me.md instead"` + `:w` — model revises the proposal
- `"also promote no semicolons"` + `:w` — model adds it
- `q` — cancel, nothing changes

The destination filename is your call. `convention-style.md` for shared/team rules, `convention-me.md` for personal preferences (gitignore that one). The plugin doesn't care; the model adapts to whatever you ask.

After promotion, the rule is stripped of its `<!-- n=N -->` annotation (conventions are canonical — the count served its purpose) and removed from learned. Future distillations won't try to re-add it because the model sees the convention files for context.

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
    -- On a fresh project (no learned-*.md yet) the threshold is forced to 1
    -- for fast feedback, regardless of this value.
    -- Set to nil to disable auto-distillation (use :NovibeDistill manually).
  },

  system_prompt = "...",
  -- Override the default system prompt entirely, or append to it:
  -- require("novibe.config").defaults.system_prompt .. "\nyour additions"
})
```

### Adding global conventions across all projects

Conventions in `.no_vibe/` are per-project. If you want rules that apply across every project, append them to the system prompt — they bypass the convention file system entirely:

```lua
require("novibe").setup({
  system_prompt = require("novibe.config").defaults.system_prompt .. [[

Personal conventions (always apply):
- Prefer early returns over nested conditionals
- Functional style: prefer map/filter/reduce over imperative loops
- No magic numbers: extract constants with descriptive names
]],
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
Write skeleton → visual select → <leader>nv
                                      ↓
                              floating input prompt
                                      ↓ :w
                    system_prompt + matched convention/learned sections
                  + 10 lines context above/below selection
                  + selection + your instruction
                                      ↓
              provider.build_cmd() → claude or opencode
                                      ↓
                          JSON response parsed
                                      ↓
                    response.code → spliced into buffer
                                      ↓
              validate change.file paths against disk
              missing? → auto-revise once (silent retry)
                                      ↓
                    out-of-scope changes? → side panel (right vsplit)
                    ok/yes → applied to target files
```

The model responds in a structured JSON schema (`{code, message, changes, done}`). The plugin splices `response.code` into your buffer immediately. Any changes outside your selection (imports, type definitions, other files) are shown as a diff in a side panel on the right — you can read the in-scope fill alongside the proposed out-of-scope diffs, and confirm before anything is written.

**Path validation**: Before opening the side panel, novibe checks every `change.file` exists on disk. If the model invented a path (more common with cheaper / less reliable models, regardless of provider), the plugin silently sends a corrective follow-up listing the missing paths and asking for a revision. Up to one retry. If validation still fails, the side panel opens anyway so you can react manually. Combined with `file_context = true` in your profile, hallucinated paths become rare.
