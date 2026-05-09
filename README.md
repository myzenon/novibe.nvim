# novibe.nvim

> *"No vibe, just smart auto completion."*

A minimal Neovim plugin that uses Claude as a **code fulfillment tool, not a vibe coder**.

You design the structure. You write the skeleton — function signature, comments describing intent and algorithm. Claude fills the implementation within your boundaries. You already understand the code because you designed it. Claude just saves you from typing boilerplate.

**This is not vibe coding.** Vibe coding (Andrej Karpathy) is when you stop understanding the code — you describe, AI generates, you accept without reading. `novibe.nvim` requires *more* thinking upfront, not less.

> **Irony disclosure:** this plugin was itself written by vibe coding. The author described, Claude generated, the author accepted without fully reading. It works great. The author understands none of it. Do as I say, not as I do.

---

**Inspired by [ThePrimeagen/99](https://github.com/ThePrimeagen/99)** — studied for how it captures visual selection in Lua, shells out to the Claude CLI, and displays the response in a buffer. novibe took the core idea and rebuilt it around a stricter philosophy: no agentic behavior, no auto-applied changes, and a stable API surface.

---

## Requirements

- Neovim 0.10+
- [Claude Code CLI](https://claude.ai/code) installed and authenticated (`claude login`)
- Any Neovim config with [lazy.nvim](https://github.com/folke/lazy.nvim)

**Optional:** [snacks.nvim](https://github.com/folke/snacks.nvim) — enables the `<C-f>` file picker in the input float (handles paths with special characters like `()`). Falls back to Neovim's built-in `<C-x><C-f>` filename completion if not available. Ships with LazyVim by default.

---

## Installation

### lazy.nvim (recommended)

```lua
{
  dir = "~/path/to/novibe.nvim",  -- or your GitHub path once published
  cmd = { "NovibeAct", "NovibeProfile", "NovibeDistill", "NovibeReset", "NovibeStatus", "NovibeConventions" },
  keys = {
    {
      "<leader>nv",
      ":NovibeAct<CR>",
      mode = "v",
      desc = "novibe: fill implementation",
    },
  },
  config = function()
    require("novibe").setup({
      bare = false,  -- set true only if auth via ANTHROPIC_API_KEY

      profiles = {
        { label = "Fast",     model = "claude-haiku-4-5-20251001", effort = "low" },
        { label = "Balanced", model = "claude-sonnet-4-6",         effort = "medium" },
        { label = "Best",     model = "claude-opus-4-7",           effort = "max" },
      },
    })
  end,
}
```

`cmd` ensures the plugin is lazy-loaded only when a command is first invoked. `keys` registers the visual-mode keymap and also acts as a lazy-load trigger.

---

## Fresh project setup

1. Open a terminal in your project root and run `claude` (interactive Claude Code CLI)
2. Run `/init` — Claude analyzes the project and generates `CLAUDE.md`
3. Tell Claude:
   > "Read https://raw.githubusercontent.com/myzenon/novibe.nvim/main/claude-init.md and follow the instructions."
4. Claude updates `CLAUDE.md` with the novibe format and generates `.no_vibe/convention-project.md`. Done.

Because Claude reads `CLAUDE.md` in every future interactive session, it will always know the convention format without you repeating it.

You can add more `convention-*.md` files later — name them however you like (`convention-frontend.md`, `convention-style.md`, etc.). All matching files are loaded and merged.

---

## Usage

### Filling a skeleton

1. Write a skeleton — function signature + comments describing what it should do
2. Visually select the block (`V` then move, or `vi{` etc.)
3. Press `<leader>nv` (or run `:'<,'>NovibeAct`)
4. A floating input appears — type an optional short instruction, or leave empty
5. Press `:w` to submit
6. Claude fills the implementation in-place

You can also run `:NovibeAct` with the cursor on a single line — no visual selection needed.

**The input float:**
- `:w` — submit
- `<Esc>` (in normal mode) or `q` — cancel
- `<C-f>` (insert mode) — file picker to insert a path at cursor

**If Claude needs to change something outside your selection** (imports, types, other files), a side panel opens on the right showing the proposed changes as a diff. The in-scope fill stays visible in your code window so you can review it side-by-side. Then:
- Type `ok` / `yes` / `lgtm` + `:w` — applies all changes immediately
- Type a free-form instruction + `:w` — sends back to Claude for revision
- `q` — discard all out-of-scope changes, keep only the in-place fill

### Switching profiles

Run `:NovibeProfile` to open a picker and select a profile. The selected profile applies for the rest of the session. With no active profile, Claude CLI uses its own default model and effort.

### Session management

novibe uses `--continue` to carry context across fills in the same Neovim session, so Claude remembers earlier code it wrote. Over a long session the context window fills up and quality quietly degrades. novibe warns you after 10 fills. Run `:NovibeReset` to start a fresh conversation on the next fill.

`:NovibeStatus` shows the active profile, bare mode, session fill count, cumulative session cost, context window usage (%), and which rule files are loaded from the current working directory.

### Usage stats

After each fill, cost and context window usage are shown in two places automatically — no extra config needed:

- **Input dialog title** — shows the previous fill's cost and context % when you open the prompt for the next fill
- **Chat side panel winbar** — updates with cost and context % after each follow-up response

```
╭── novibe  $0.0039 · ctx 6% ───╮   ← previous fill stats
│                                │
╰─ :w submit · q cancel · <C-f> ╯
```

**Context %** is the most useful signal: it shows how full the `--continue` session context is. As it climbs (30–40%+), quality can degrade — run `:NovibeReset` to start fresh.

**Optional lualine integration** — to keep stats always visible in the statusline:

```lua
-- in your lualine setup
lualine_x = {
  { require("novibe").statusline },
  -- ... your other components
}
```

### Teaching your style

After novibe fills code, edit the result to match your style. Then select the edited block, run `:NovibeAct`, and type `#teach` with a reason:

```
#teach i prefer for loop over map
#teach always use early return instead of nested if
#teach named function over arrow function for exports
```

Each `#teach` saves a diff of what Claude wrote vs what you changed it to. Once enough diffs accumulate (default: 1 on a fresh project, 3 after rules exist), novibe automatically distills rules into topic-organized files in `.no_vibe/` — `learned-style.md`, `learned-react.md`, etc. Rules there are injected into every future prompt — Claude learns your style from real examples, not hand-written rules.

Run `:NovibeDistill` to force extraction at any time. Run `:NovibeConventions` to browse and open convention/learned files in a picker.

---

## Profiles

Profiles combine a model and an effort level into a named preset. You define them yourself — there are no built-in defaults.

```lua
require("novibe").setup({
  profiles = {
    { label = "Fast",     model = "claude-haiku-4-5-20251001", effort = "low" },
    { label = "Balanced", model = "claude-sonnet-4-6",         effort = "medium" },
    { label = "Best",     model = "claude-opus-4-7",           effort = "max" },
  },
})
```

**`model`** — full model ID or alias accepted by the Claude CLI:

| Alias | Full ID |
|---|---|
| `haiku` | `claude-haiku-4-5-20251001` |
| `sonnet` | `claude-sonnet-4-6` |
| `opus` | `claude-opus-4-7` |

**`effort`** — maps directly to Claude CLI's `--effort` flag. Five levels along a speed ↔ intelligence trade-off:

| Level | Notes |
|---|---|
| `low` | Fastest, least reasoning |
| `medium` | Default |
| `high` | More reasoning, slower |
| `xhigh` | Deeper reasoning — **Opus 4.7 only** |
| `max` | Maximum reasoning |

> The Claude CLI documents `xhigh` as Opus-only. Other levels may also have model restrictions — check `/effort` inside an interactive `claude` session to see which levels are available for the model you've selected.

Profiles are entirely yours to define. Add as many as you need, name them however you like, and mix model/effort freely.

---

## Conventions — Rules for Claude

novibe loads rules from these sources (in order):

1. `NO_VIBE.md` at project root — optional single-file shortcut
2. `.no_vibe/convention-*.md` — human-written rules. Any number of files, named freely after `convention-`. Split however suits you (by topic, layer, ownership — your call).
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

Only the `## always` section + sections matching the current filename are sent to Claude — nothing leaks across file types.

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

Only the `always` section + sections matching the **current file being edited** are sent to Claude. A hooks file never sees CSS conventions. A component file never sees backend rules.

### Example .no_vibe/convention-project.md

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

You can use Claude (or any AI) to generate a rules file for your project. Paste this prompt:

---

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
> [describe your stack, libraries, patterns, and anything Claude should always or never do]
>
> Generate the file now.

---

**Tips for good rules:**
- **Be specific about libraries**: "MUI only" not "use a UI library"
- **Name what to avoid**: "never style={{}}" is better than "prefer sx prop"
- **One decision per rule**: don't combine multiple constraints in one line
- **File-type rules should be truly file-type specific** — if it applies everywhere, put it in `always`
- **Split however helps you**: any `convention-*.md` filename works — split by topic, layer, or whatever makes the rules easiest to maintain

---

## How It Works

```
Write skeleton → visual select → <leader>nv
                                      ↓
                              floating input prompt
                                      ↓ :w
                    system_prompt + matched convention/learned sections
                  + 10 lines context above/below selection
                  + selection + your instruction
                                      ↓
          claude [--model X] [--effort Y] --continue --print "..."
                                      ↓
                          JSON response parsed
                                      ↓
                    response.code → spliced into buffer
                                      ↓
                    out-of-scope changes? → side panel (right vsplit)
                    ok/yes → applied to target files
```

Claude responds in a structured JSON schema. The plugin splices `response.code` into your buffer immediately. Any changes outside your selection (imports, type definitions, other files) are shown as a diff in a side panel on the right — you can read the in-scope fill in your code window while reviewing the proposed out-of-scope diffs alongside it, and confirm before anything is written.

---

## Configuration

```lua
require("novibe").setup({
  -- No keymap default — define it in lazy.nvim keys spec (see Installation)

  bare = false,
  -- true = --bare flag (faster, skips plugins/hooks/memory)
  -- only works with ANTHROPIC_API_KEY auth, not claude login

  profiles = {},
  -- No defaults — define your own (see Profiles section)
  -- No active profile = Claude CLI picks model and effort

  learn = {
    auto_extract_after = 3,
    -- Number of #teach diffs that triggers automatic distillation.
    -- On a fresh project (no learned-*.md yet) the threshold is forced
    -- to 1 for fast feedback, regardless of this value.
    -- Set to nil to disable auto-distillation (use :NovibeDistill manually).
  },

  system_prompt = "...",
  -- Override the default system prompt entirely, or append to it:
  -- require("novibe.config").defaults.system_prompt .. "\nyour additions"
})
```

### Adding global conventions across all projects

If you want conventions that apply across every project (not per-project), append them directly to the system prompt in your config — they bypass the convention file system entirely:

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
