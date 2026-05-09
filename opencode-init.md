# novibe.nvim — opencode onboarding

You are being asked to set up novibe.nvim for this project.

novibe.nvim is a Neovim plugin that sends code selections to an AI CLI for implementation. It reads convention files from `.no_vibe/` and injects matching sections into every prompt — so the model always follows the project's conventions without the user repeating them.

## Step 1 — Add novibe format to AGENTS.md

Append the following section to this project's `AGENTS.md` (create it if missing):

```markdown
## novibe conventions

novibe.nvim loads rules from `.no_vibe/` (and `NO_VIBE.md` at root for legacy/simple projects).

Files, in load order:
1. `NO_VIBE.md` — single-file shortcut at project root (optional)
2. `.no_vibe/convention-*.md` — human-written rules. Any number of files, named freely after `convention-`. Split however suits the project (by topic, layer, ownership — your call).
3. `.no_vibe/learned-*.md` — auto-distilled by `:NovibeDistill` from `#teach` diffs. Do NOT hand-edit these.

Section format (same for every file):
- `## always` — rules that apply to every file
- `## *.ext` — rules for files matching the glob (comma-separated patterns allowed: `## *.tsx, *.jsx`)
- `**` matches any path including separators, `*` matches within a single segment
- One rule per line starting with `-`
- No prose, no explanations — directives only

When asked to create or update convention files, always follow this format. Never edit `learned-*.md` directly.
```

## Step 2 — Generate the project convention file

Analyze this project (stack, libraries, patterns, existing code) and generate `.no_vibe/convention-project.md`.

Cover:
- Universal rules under `## always` (imports, types, error handling, naming)
- File-type rules under appropriate glob headers (components, hooks, services, tests, etc.)
- Only add a section if there are real conventions to enforce — omit sections you have no signal for

Write the file directly. Do not explain it, do not summarize — just write it.

After writing, briefly tell the user:
- That `AGENTS.md` and `.no_vibe/convention-project.md` are now set up
- That they can add more `convention-*.md` files later, named however they like, to split rules by topic or scope
- That they should add `.no_vibe/diffs.json` to `.gitignore` (transient working state)
