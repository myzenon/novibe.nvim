# novibe.nvim

> _"No vibe, just smart auto completion."_

A minimal Neovim plugin that uses your AI coding CLI ([Claude Code](https://claude.ai/code), [opencode](https://opencode.ai/), [Gemini CLI](https://geminicli.com/), or [OpenAI Codex](https://github.com/openai/codex)) as a **code fulfillment tool, not a vibe coder**.

You design the structure. You write the skeleton — function signature, comments describing intent and algorithm. The model fills the implementation within your boundaries. You already understand the code because you designed it.

**This is not vibe coding.** Vibe coding (Andrej Karpathy) is when you stop understanding the code — you describe, AI generates, you accept without reading. `novibe.nvim` requires _more_ thinking upfront, not less.

> **Irony disclosure:** this plugin was itself written by vibe coding. The author described, an AI agent generated, the author accepted without fully reading. Do as I say, not as I do.

**Inspired by [ThePrimeagen/99](https://github.com/ThePrimeagen/99)** — rebuilt around a stricter philosophy: no agentic behavior, no auto-applied changes, stable API.

---

## Requirements

- Neovim 0.10+
- One of: [Claude Code CLI](https://claude.ai/code) (`claude login`), [opencode](https://opencode.ai/) (`opencode auth login`), [Gemini CLI](https://geminicli.com/) (`gemini auth`), or [OpenAI Codex](https://github.com/openai/codex) (`codex login`)
- [lazy.nvim](https://github.com/folke/lazy.nvim)
- [snacks.nvim](https://github.com/folke/snacks.nvim) — file picker (`<C-f>`) in the input float

---

## Installation

```lua
{
  "myzenon/novibe.nvim",
  dependencies = { "folke/snacks.nvim" },
  cmd = { "NovibeAct", "NovibeAct2", "NovibeGen", "NovibeConsult", "NovibeConsultPrompt", "NovibeProfile", "NovibeDistill", "NovibePromote", "NovibeReset", "NovibeStatus", "NovibeKB", "NovibeActReviewFocus" },
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
        { label = "Gemini Flash", provider = "gemini",   model = "gemini-2.0-flash" },
        { label = "Codex o4",     provider = "codex",    model = "o4-mini", effort = "high" },
        -- Run `opencode models` or check `/model` in `gemini`/`codex` for available models. See docs/config.md.
      },
    })
  end,
}
```

See **[docs/config.md](./docs/config.md)** for full configuration, profiles, conventions, provider differences, and the system prompt.

---

## First-time project setup

Bootstrap your project conventions by running your AI CLI in the project root:

- **Claude Code** — start `claude`, then paste: `"Read https://raw.githubusercontent.com/myzenon/novibe.nvim/main/docs/claude-init.md and follow the instructions."`
- **opencode** — start `opencode`, then paste: `"Read https://raw.githubusercontent.com/myzenon/novibe.nvim/main/docs/opencode-init.md and follow the instructions."`
- **Gemini CLI** — start `gemini`, trust the workspace when prompted, then paste: `"Read https://raw.githubusercontent.com/myzenon/novibe.nvim/main/docs/gemini-init.md and follow the instructions."`
- **Codex** — start `codex`, then paste: `"Read https://raw.githubusercontent.com/myzenon/novibe.nvim/main/docs/codex-init.md and follow the instructions."`

The agent analyzes your project, generates `.no_vibe/convention-project.md`, and writes the novibe format spec into `CLAUDE.md` (claude) / `AGENTS.md` (opencode, codex) / `GEMINI.md` (gemini) so it auto-loads in future sessions.

See [docs/config.md → Fresh project setup](./docs/config.md#fresh-project-setup) for details.

---

## Usage

### Fill a skeleton

1. Write a skeleton — function signature + comments describing what it should do
2. Visually select the block (`V` then move, or `vi{` etc.)
3. Press `<leader>aa` (or run `:'<,'>NovibeAct`)
4. Type an optional short instruction in the floating input → `:w` to submit
5. A fill-preview split opens on the right; code streams in as it arrives

You can also run `:NovibeAct` with the cursor on a single line — no visual selection needed.

**Input float:** `:w` submit · `<Esc>`/`q` cancel · `<C-f>` file picker (insert mode)

**Review queue** — when the stream finishes, each proposed change appears one at a time:

| Key | Action |
|---|---|
| `<CR>` | Apply this change and advance |
| `s` | Skip (don't apply), advance |
| `:w <text>` | Send feedback to the AI; AI revises the current question; unreviewed questions are preserved |
| `:w #teach <reason>` | Capture the reason as a style note (no AI call, no change to the queue) — see [docs/teach.md](docs/teach.md) |
| `:w all` | Apply every remaining change and close |
| `q` | Quit; already-applied changes stay |

In-scope code (your selection) appears first, shown as a `-`/`+` diff against your original with 3 lines of surrounding context and line numbers — so you can see exactly where the new code lands. Out-of-scope changes (imports, types, other files) follow with the same diff view, pulling context from the actual file on disk.

Hallucinated paths are flagged inline with `⚠` so you can revise or skip before wasting a confirm.

A virtual line appears below your selection in the working buffer once the review is ready — it clears automatically when the chat closes. Use `i`/`a` in the chat window to jump straight to the reply area regardless of where your cursor is. If you're in insert mode when the chat opens, `:NovibeActReviewFocus` jumps to it without leaving the keyboard.

### Act2 — no chat window

`:NovibeAct2` is an alternative fill approach that skips the chat window entirely. Instead of a side split, AI code is written directly into your buffer and review controls appear as virtual lines above and below the filled scope:

```
⠋  staying in scope…          ← spinner while AI runs
  function myFn() {           ← your selection (unchanged)
    // TODO
  }
⠏  staying in scope…

→ when done:

  <CR> accept  ·  U undo  ·  r re-prompt  ·  t teach
  function myFn() {           ← original lines still in buffer
    // TODO
  }
  <CR> accept  ·  U undo  ·  r re-prompt  ·  t teach
```

| Key | Scope | Action |
|---|---|---|
| `<CR>` | cursor in scope | Splice AI code into buffer; show out-of-scope changes in a non-focused bottom split |
| `U` | cursor in scope | Undo: restore original lines (or cancel teach mode) |
| `<leader>r` | cursor in scope | Re-prompt: restore original and reopen input float pre-filled |
| `<leader>t` | cursor in scope | Phase 1: accept + enter edit mode (edit AI code freely); Phase 2: open reason float, capture diff, call teach |

All keys pass through to native vim when the cursor is outside the scope. Remap any key that conflicts with your setup via `setup({ act2 = { keys = { teach = "<leader>t", ... } } })`.

**Out-of-scope changes** (imports, types, other files) appear in a read-only bottom split — you apply them manually. Close with `q`.

**Teach flow** (`t`): press `t` → code is accepted and you can edit it in-place → press `t` again → type your reason → diff (AI output vs your edit) is captured automatically. No re-selection, no `#teach` prefix needed.

### Generate new files

Run `:NovibeGen` to generate one or more new files from a description:

```
create a React UserProfile component with name/avatar props using shadcn Card
create a db repository for the User model
```

If you have a file open, novibe injects it as reference context automatically.

**Pending list:** `:NovibeGen` shows an input prompt when there are no pending files, or a picker of pending files when there are. Finish (save or wipe) the current batch before starting a new one.

Each proposed file opens as a regular buffer with a winbar showing the save path and available actions:

```
  novibe  src/components/UserProfile.tsx  ·  <C-f> change path  ·  <leader>r re-prompt  ·  :w save
```

| Key | Action |
|---|---|
| `<C-f>` | Edit the save path (input float pre-filled with current path) |
| `<leader>r` | Re-prompt — regenerate the file with a revised description |
| `:w` | Save the file to the path shown in the winbar |

No auto-apply — you save each file yourself, so hallucinated paths never silently write to the wrong location.

---

## Commands

| Command              | What                                                         |
| -------------------- | ------------------------------------------------------------ |
| `:NovibeAct`         | Fill selection (or current line) · `#teach <reason>` to capture style evidence |
| `:NovibeAct2`        | Fill in-place with virt_line review controls — no chat window. `<CR>` accept · `U` undo · `<leader>r` re-prompt · `<leader>t` teach |
| `:NovibeGen`         | Generate new files — prompt if no pending files, list if pending. `<C-f>` change path · `<leader>r` re-prompt · `:w` save |
| `:NovibeConsult`     | Open interactive consult session (vsplit); claude / gemini / codex: context auto-injected; opencode: manual |
| `:NovibeConsultPrompt` | Push consult seed into the active consult terminal (required for opencode; works with any provider) |
| `:NovibeProfile`     | Two-step picker: choose slot (Act / Consult), then profile   |
| `:NovibeReset`       | Start a fresh session on the next fill                       |
| `:NovibeStatus`      | Show profile, session, cost, ctx %, loaded rule files        |
| `:NovibeKB`          | Browse all `.no_vibe` files by category (convention, learn, map, rule, decision) |
| `:NovibeDistill`     | Force `#teach` distillation now                              |
| `:NovibePromote`     | Review mature learned rules and graduate them to conventions |
| `:NovibeActReviewFocus` | Focus the active fill-preview chat window (useful when in insert mode) |

---

## Teach your style

After a fill, edit the result to match your preference, re-select, and run `:NovibeAct` with `#teach <reason>`. novibe captures the diff, distills it into a rule, and eventually promotes it to a convention — all from real examples, not hand-written rules.

See **[docs/teach.md](./docs/teach.md)** for the full teach → distill → promote guide, both teach modes, the lifecycle diagram, and tips.

---

## Usage stats

After each fill, cost and context window % show automatically in:

- The input dialog title (previous fill's stats)
- The chat side panel winbar (live, after each follow-up)

Optional lualine integration for persistent display — see [docs/config.md → Statusline integration](./docs/config.md#statusline-integration).

**Context %** is the most useful signal: as the `--continue` session fills up (30–40%+), quality can degrade — run `:NovibeReset` to start fresh.

---

For profiles, conventions, provider differences, and full configuration → **[docs/config.md](./docs/config.md)**.
