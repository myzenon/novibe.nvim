# novibe.nvim

> _"No vibe, just smart auto completion."_

A minimal Neovim plugin that uses your AI coding CLI ([Claude Code](https://claude.ai/code) or [opencode](https://opencode.ai/)) as a **code fulfillment tool, not a vibe coder**.

You design the structure. You write the skeleton — function signature, comments describing intent and algorithm. The model fills the implementation within your boundaries. You already understand the code because you designed it.

**This is not vibe coding.** Vibe coding (Andrej Karpathy) is when you stop understanding the code — you describe, AI generates, you accept without reading. `novibe.nvim` requires _more_ thinking upfront, not less.

> **Irony disclosure:** this plugin was itself written by vibe coding. The author described, an AI agent generated, the author accepted without fully reading. Do as I say, not as I do.

**Inspired by [ThePrimeagen/99](https://github.com/ThePrimeagen/99)** — rebuilt around a stricter philosophy: no agentic behavior, no auto-applied changes, stable API.

---

## Requirements

- Neovim 0.10+
- One of: [Claude Code CLI](https://claude.ai/code) (`claude login`) or [opencode](https://opencode.ai/) (`opencode auth login`)
- [lazy.nvim](https://github.com/folke/lazy.nvim)

Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) for the `<C-f>` file picker in the input float.

---

## Installation

```lua
{
  "myzenon/novibe.nvim",
  cmd = { "NovibeAct", "NovibeConsult", "NovibeProfile", "NovibeDistill", "NovibePromote", "NovibeReset", "NovibeStatus", "NovibeConventions", "NovibeLearns" },
  keys = {
    { "<leader>aa", ":NovibeAct<CR>", mode = "v", desc = "novibe: fill implementation" },
    { "<leader>aa", ":NovibeAct<CR>", mode = "n", desc = "novibe: act on current line" },
  },
  config = function()
    require("novibe").setup({
      profiles = {
        { label = "Claude Best",  provider = "claude",   model = "opus",                       effort = "max"  },
        { label = "OC DeepSeek",  provider = "opencode", model = "opencode-go/deepseek-v4-pro", effort = "high", file_context = false },
        { label = "OC Qwen",      provider = "opencode", model = "opencode-go/qwen3.6-plus",    effort = "high", file_context = true },
        -- Run `opencode models` to see everything available. See CONFIG.md for full options.
      },
    })
  end,
}
```

See **[CONFIG.md](./CONFIG.md)** for full configuration, profiles, conventions, provider differences, and the system prompt.

---

## First-time project setup

Bootstrap your project conventions by running your AI CLI in the project root:

- **Claude Code** — start `claude`, then paste: `"Read https://raw.githubusercontent.com/myzenon/novibe.nvim/main/claude-init.md and follow the instructions."`
- **opencode** — start `opencode`, then paste: `"Read https://raw.githubusercontent.com/myzenon/novibe.nvim/main/opencode-init.md and follow the instructions."`

The agent analyzes your project, generates `.no_vibe/convention-project.md`, and writes the novibe format spec into `CLAUDE.md` / `AGENTS.md` so it auto-loads in future sessions.

See [CONFIG.md → Fresh project setup](./CONFIG.md#fresh-project-setup) for details.

---

## Usage

1. Write a skeleton — function signature + comments describing what it should do
2. Visually select the block (`V` then move, or `vi{` etc.)
3. Press `<leader>aa` (or run `:'<,'>NovibeAct`)
4. Type an optional short instruction in the floating input → `:w` to submit
5. Implementation is spliced in place

You can also run `:NovibeAct` with the cursor on a single line — no visual selection needed.

**Input float:** `:w` submit · `<Esc>`/`q` cancel · `<C-f>` file picker (insert mode)

**Out-of-scope changes** (imports, types, other files) open a side panel showing diffs:

- `ok` / `yes` / `lgtm` + `:w` — apply all
- Free-form text + `:w` — request revision from the model
- `q` — discard

---

## Commands

| Command              | What                                                         |
| -------------------- | ------------------------------------------------------------ |
| `:NovibeAct`         | Fill selection (or current line)                             |
| `:NovibeConsult`     | Open interactive consult session (vsplit); Claude: context auto-injected; opencode: manual |
| `:NovibeProfile`     | Pick the active profile (model + effort + provider)          |
| `:NovibeReset`       | Start a fresh session on the next fill                       |
| `:NovibeStatus`      | Show profile, session, cost, ctx %, loaded rule files        |
| `:NovibeConventions` | Browse canonical `convention-*.md` files                     |
| `:NovibeLearns`      | Browse staged `learned-*.md` files                           |
| `:NovibeDistill`     | Force `#teach` distillation now                              |
| `:NovibePromote`     | Review mature learned rules and graduate them to conventions |

---

## Teach your style

After a fill, edit the result to match your taste, re-select, run `:NovibeAct` with `#teach <reason>`:

```
#teach prefer for loop over map
#teach always use early return instead of nested if
#teach named function over arrow function for exports
```

novibe accumulates the diffs and auto-distills topic-organized rules into `.no_vibe/learned-*.md` (e.g. `learned-style.md`, `learned-react.md`). Each rule carries a support count — the more diffs that reinforce it, the higher the count. The model learns your style from real examples, not hand-written rules.

Run `:NovibePromote` to review mature learned rules and graduate them into canonical `convention-*.md` files. See [CONFIG.md → Promotion](./CONFIG.md#promotion).

---

## Usage stats

After each fill, cost and context window % show automatically in:

- The input dialog title (previous fill's stats)
- The chat side panel winbar (live, after each follow-up)

Optional lualine integration for persistent display — see [CONFIG.md → Statusline integration](./CONFIG.md#statusline-integration).

**Context %** is the most useful signal: as the `--continue` session fills up (30–40%+), quality can degrade — run `:NovibeReset` to start fresh.

---

For profiles, conventions, provider differences, and full configuration → **[CONFIG.md](./CONFIG.md)**.
