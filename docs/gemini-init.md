# novibe.nvim — Gemini onboarding

You are being asked to set up novibe.nvim for this project.

novibe.nvim is a Neovim plugin that sends code selections to an AI CLI for implementation. It reads convention files from `.no_vibe/` and injects matching sections into every prompt — so the model always follows the project's conventions without the user repeating them.

## Step 1 — Add novibe format to GEMINI.md

Append the following section to this project's `GEMINI.md` (create it if missing):

```markdown
## novibe conventions

novibe.nvim loads rules from `.no_vibe/` (and `NO_VIBE.md` at root for legacy/simple projects).

Files, in load order:
1. `NO_VIBE.md` — single-file shortcut at project root (optional)
2. `.no_vibe/convention-*.md` — human-written rules. Any number of files, named freely after `convention-`. Split however suits the project (by topic, layer, ownership — your call).
3. `.no_vibe/learned-*.md` — auto-distilled by `:NovibeDistill` from `#teach` diffs. Do NOT hand-edit these.
4. `.no_vibe/map-*.md` — dependency graphs: call chains, inheritance, who depends on what.
5. `.no_vibe/rule-*.md` — behavioral constraints: how to interact with each area (e.g. "always use Class X as db proxy").
6. `.no_vibe/decision-*.md` — architectural ADRs: the why behind decisions and rejected alternatives.

Section format (same for every file):
- `## always` — rules that apply to every file
- `## *.ext` — rules for files matching the glob (comma-separated patterns allowed: `## *.tsx, *.jsx`)
- `**` matches any path including separators, `*` matches within a single segment
- One rule per line starting with `-`
- No prose, no explanations — directives only

Knowledge base sections (map/rule/decision) may include a `<!-- last-verified: HASH -->` comment. If the area has changed since that commit, novibe will prefix the section with a staleness warning.

When asked to create or update convention files, always follow this format. Never edit `learned-*.md` directly.
```

## Step 2 — Generate the project convention file

Analyze this project (stack, libraries, patterns, existing code) and generate `.no_vibe/convention-project.md`.

Cover:
- Universal rules under `## always` (imports, types, error handling, naming)
- File-type rules under appropriate glob headers (components, hooks, services, tests, etc.)
- Only add a section if there are real conventions to enforce — omit sections you have no signal for

Write the file directly. Do not explain it, do not summarize — just write it.

## Step 3 — Seed the knowledge base (optional but recommended)

If the project has non-obvious structural knowledge worth preserving (key dependency chains, proxy classes, architectural decisions), create one or more knowledge base files:

- `.no_vibe/map-<area>.md` — structural: who calls what, inheritance chains
- `.no_vibe/rule-<area>.md` — behavioral: constraints on how to interact with an area
- `.no_vibe/decision-<area>.md` — reasoning: why something was built this way, what was rejected

Each file uses the same section-header format. Add `<!-- last-verified: <current-git-hash> -->` after the header so novibe can detect when the area changes.

You can also grow the knowledge base lazily during `:NovibeConsult` sessions: the seed context is injected via `--prompt-interactive` when Gemini starts. Say **"snapshot"** whenever you discover something worth keeping, and write it to the right file with the current commit hash.

Note: the workspace must be trusted before Gemini CLI will run non-interactively. Either run `gemini` interactively once and trust the directory, or set `GEMINI_CLI_TRUST_WORKSPACE=true` in your environment.

## Step 4 — Tell the user their ongoing workflows

After completing the above steps, tell the user about the three loops they'll use day-to-day:

**Teaching the model (`#teach` + `:NovibeDistill`)**
- After `:NovibeAct` fills a selection, edit the result if needed, re-select it, and run `:NovibeAct` again with `#teach <reason>` as the instruction. novibe captures the diff (original fill → your correction) as evidence.
- You can also run `:NovibeAct` on any selection with `#teach <reason>` without a prior fill — it records a direct rule note instead.
- Once enough evidence accumulates (default: 3 diffs, or 1 if no learned files exist yet), `:NovibeDistill` merges everything into topic-organized `.no_vibe/learned-*.md` files automatically. You can also run `:NovibeDistill` manually at any time.
- Never hand-edit `learned-*.md` — they are owned by distillation.

**Growing the knowledge base (`:NovibeConsult` + "snapshot")**
- Open a consult session with `:NovibeConsult`. The seed context (file, line, conventions) is injected via `--prompt-interactive` when Gemini starts.
- Explore the codebase, ask questions, investigate dependencies.
- Say **"snapshot"** whenever you discover something worth keeping. Write it to the right `map-*`, `rule-*`, or `decision-*` file with the current commit hash for staleness tracking.
- The knowledge base grows lazily as you touch areas — no need to document everything upfront.

**Switching models (`:NovibeProfile`)**
- Run `:NovibeProfile` to open a two-step picker: choose a slot (Act or Consult), then a profile. Each slot persists independently.
- Profiles are defined in your `setup()` call with `provider = "gemini"` and `model`. `effort` is ignored for Gemini (no CLI equivalent). No active profile = CLI defaults.
- Use a fast model (e.g. `gemini-2.0-flash`) for routine fills and a powerful one (e.g. `gemini-2.5-pro`) for complex consult sessions.

Finally, tell the user:
- Add `.no_vibe/diffs.json` to `.gitignore` (transient working state, not meant to be committed)
- They can split conventions into multiple `convention-*.md` files at any time — novibe loads all of them
- Ensure `GEMINI_CLI_TRUST_WORKSPACE=true` is set (or trust the workspace interactively once) so non-interactive runs work

## Step 5 — Optional: session task tracking

Ask the user: "Would you like to enable task tracking? This keeps a running note of your current state injected into every novibe prompt — so you never lose context when switching machines or tools, or when hitting a rate limit and continuing in a different AI."

If the user says yes, interview them with these questions before writing anything:

1. "Do you work from a plan — a numbered list of tasks you check off one by one? Or do you prefer to just track the current focus and next step?"
2. "When you ask an AI to make a plan before coding, do you want that plan saved to task.md so you can continue it on another machine or tool?"
3. "Do you want to track blockers and open questions?"
4. "Is there any other context you always want carried across sessions — e.g. active branch, ticket number, decisions already made?"

Based on their answers, do the following:

1. Generate a `task.md` template that matches how they described their workflow. The only requirement is that it starts with `## always` (so novibe injects it into every prompt). Keep it under 20 lines. Examples:

   Plan-oriented user:
   ```
   ## always
   **Goal:** <overall goal>
   **Plan:**
   - [x] Task 1: <description>
   - [ ] Task 2: <description> ← current
   - [ ] Task 3: <description>
   **Blockers:** none
   ```

   Focus-oriented user:
   ```
   ## always
   **Working on:** <current focus>
   **Done so far:** <summary>
   **Next:** <immediate next action>
   ```

   Write the generated template to `.no_vibe/task.md`.

2. Append a matching "update task" rule to `.no_vibe/convention-project.md` that describes the exact format to use — so every AI on every machine produces consistent output. Example:

   ```
   ## always
   - When asked to "update task", rewrite `.no_vibe/task.md` keeping the `## always` header and using the format already in the file. Mark completed plan items with [x]. Keep it under 20 lines.
   ```

3. Append this block to `GEMINI.md` (create it if missing):

   ```markdown
   ## Session state
   At the start of each session, if `.no_vibe/task.md` exists, read it and acknowledge the current task state in one sentence.
   When creating a multi-step plan before coding, write the plan to `.no_vibe/task.md` immediately so it survives across sessions and tools.
   When asked to "update task", rewrite `.no_vibe/task.md` as instructed in `.no_vibe/convention-project.md`.
   ```
