# novibe.nvim

> *"No vibe, just smart auto completion."*

A minimal Neovim plugin that uses Claude (or opencode) as a **code fulfillment tool, not a vibe coder**.

You design the structure. You write the skeleton — function signature, comments describing intent and algorithm. The model fills the implementation within your boundaries. You already understand the code because you designed it.

**This is not vibe coding.** Vibe coding (Andrej Karpathy) is when you stop understanding the code — you describe, AI generates, you accept without reading. `novibe.nvim` requires *more* thinking upfront, not less.

> **Irony disclosure:** this plugin was itself written by vibe coding. The author described, Claude generated, the author accepted without fully reading. Do as I say, not as I do.

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
  cmd = { "NovibeAct", "NovibeProfile", "NovibeDistill", "NovibeReset", "NovibeStatus", "NovibeConventions" },
  keys = {
    { "<leader>nv", ":NovibeAct<CR>", mode = "v", desc = "novibe: fill implementation" },
  },
  config = function()
    require("novibe").setup({
      profiles = {
        { label = "Fast", provider = "claude", model = "haiku", effort = "low" },
        { label = "Best", provider = "claude", model = "opus",  effort = "max" },
      },
    })
  end,
}
```

See **[CONFIG.md](./CONFIG.md)** for full configuration, profiles, conventions, opencode setup, and the system prompt.

---

## Usage

1. Write a skeleton — function signature + comments describing what it should do
2. Visually select the block (`V` then move, or `vi{` etc.)
3. Press `<leader>nv` (or run `:'<,'>NovibeAct`)
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

| Command | What |
|---|---|
| `:NovibeAct` | Fill selection (or current line) |
| `:NovibeProfile` | Pick the active profile (model + effort + provider) |
| `:NovibeReset` | Start a fresh session on the next fill |
| `:NovibeStatus` | Show profile, session, cost, ctx %, loaded rule files |
| `:NovibeConventions` | Browse convention/learned files in a picker |
| `:NovibeDistill` | Force `#teach` distillation now |

---

## Teach your style

After a fill, edit the result to match your taste, re-select, run `:NovibeAct` with `#teach <reason>`:

```
#teach prefer for loop over map
#teach always use early return instead of nested if
#teach named function over arrow function for exports
```

novibe accumulates the diffs and auto-distills topic-organized rules into `.no_vibe/learned-*.md` (e.g. `learned-style.md`, `learned-react.md`). The model learns your style from real examples, not hand-written rules. See [CONFIG.md → Conventions](./CONFIG.md#conventions).

---

## Usage stats

After each fill, cost and context window % show automatically in:

- The input dialog title (previous fill's stats)
- The chat side panel winbar (live, after each follow-up)

Optional lualine integration for persistent display — see [CONFIG.md → Statusline integration](./CONFIG.md#statusline-integration).

**Context %** is the most useful signal: as the `--continue` session fills up (30–40%+), quality can degrade — run `:NovibeReset` to start fresh.

---

For profiles, conventions, opencode setup, and full configuration → **[CONFIG.md](./CONFIG.md)**.
