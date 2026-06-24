# novibe.nvim — Claude onboarding

You are being asked to set up or refresh novibe.nvim for this project.

novibe.nvim is a Neovim plugin that sends code selections to Claude CLI for implementation. It reads project knowledge from `.no_vibe/` and injects matching content into every prompt — so Claude always follows the project's conventions without the user repeating them.

**This init can be run multiple times.** On a re-run, expand and merge — do not overwrite existing content. Add new topic areas you discover, update index.md with new entries, and add doc.md/why.md for areas that have grown. Never replace a rule.md that already has content unless the user explicitly asks.

## Step 1 — Choose your setup mode

Ask the user which mode they want:

> **A — Hybrid**: novibe format is added to `CLAUDE.md` so Claude Code always knows the `.no_vibe/` structure, even in interactive sessions and agent tasks outside of novibe fills. Best when you already use `CLAUDE.md` for project conventions or want the whole team to benefit.
>
> **B — Pure novibe**: no `CLAUDE.md` needed. The `.no_vibe/` KB is the single source of truth — novibe injects context at fill time. Any existing team `CLAUDE.md` (if present) handles base CLI behavior only; project conventions live entirely in `.no_vibe/topics/`.

### Mode A — Hybrid: append to CLAUDE.md

Append the following section to this project's `CLAUDE.md` (create it if missing):

```markdown
## novibe conventions

novibe.nvim loads knowledge from `.no_vibe/`:

- `NO_VIBE.md` — single-file shortcut at project root (optional, simple projects)
- `.no_vibe/config.md` — personal config: `## Always`, `## Act`, `## Agent` sections
- `.no_vibe/topics/index.md` — routing: `## Area Name [glob]` entries pointing to topic folders
- `.no_vibe/topics/<area>/rule.md` — behavioral constraints for that area
- `.no_vibe/topics/<area>/doc.md` — structural knowledge, call chains (agent on-demand)
- `.no_vibe/topics/<area>/why.md` — architectural decisions, rejected alternatives (agent on-demand)
- `.no_vibe/act/learned-*.md` — auto-distilled from `#teach` diffs (do NOT hand-edit)

`topics/index.md` format:
  ## Area Name [src/feature/**]
  One-line description of when to load this topic.
  - topics/area/

  ## Always
  Global rules that apply to every file.
  - topics/global/

`NO_VIBE.md` and `act/learned-*.md` use glob-section headers:
- `## always` — applies to every file
- `## *.tsx, *.jsx` — applies to matching files (comma-separated globs)

Topics `rule.md` files are loaded whole — the index handles routing by filename glob.

Knowledge base files may include `<!-- last-verified: HASH -->`. If the area has changed since that commit, novibe prefixes the section with a staleness warning.
```

### Mode B — Pure novibe: skip CLAUDE.md

Skip the instruction file entirely. The knowledge base built in Step 2 is the full source of truth for novibe. If a team `CLAUDE.md` already exists in the repo, Claude Code will still read it for base behavior — novibe's KB adds on top at fill time.

## Step 2 — Generate the initial knowledge base

Analyze this project (stack, libraries, patterns, existing code) and create the initial topic files.

1. Create `.no_vibe/topics/index.md` with the areas you discover. Each entry:

   ```
   ## Area Name [glob/pattern/**]
   One-line description of what this area covers.
   - topics/<area>/
   ```

   Include an `## Always` entry for rules that apply globally, if any exist.

2. For each area in the index, create `.no_vibe/topics/<area>/rule.md` with behavioral rules for that area. Write rules directly — no explanations, no prose, directives only.

Only create a rule.md for an area if you have real signal from the codebase. Omit areas you have no conventions for.

## Step 3 — Seed the knowledge base (optional but recommended)

If the project has non-obvious structural knowledge worth preserving (dependency chains, proxy classes, architectural decisions), create additional files per area:

- `.no_vibe/topics/<area>/doc.md` — how features work, call chains, structural knowledge
- `.no_vibe/topics/<area>/why.md` — why something was built this way, what was rejected

Add `<!-- last-verified: <current-git-hash> -->` at the top of each file so novibe can detect when the area changes.

You can also grow the knowledge base lazily during `:NovibeConsult` sessions: say **"snapshot"** whenever you discover something worth keeping, and the AI will write it to the right topic folder with the current commit hash.

## Step 4 — Tell the user their ongoing workflows

After completing the above steps, tell the user about the three loops they'll use day-to-day:

**Teaching the model (`#teach` + `:NovibeDistill`)**
- After `:NovibeAct` fills a selection, edit the result if needed, re-select it, and run `:NovibeAct` again with `#teach <reason>` as the instruction. novibe captures the diff (original fill → your correction) as evidence.
- You can also run `:NovibeAct` on any selection with `#teach <reason>` without a prior fill — it records a direct rule note instead.
- Once enough evidence accumulates (default: 3 diffs, or 1 if no learned files exist yet), `:NovibeDistill` merges everything into `.no_vibe/act/learned-*.md` automatically. You can also run `:NovibeDistill` manually at any time.
- Never hand-edit `act/learned-*.md` — they are owned by distillation.
- When learned rules mature (n≥3), use `:NovibePromote` to graduate them into `topics/<area>/rule.md`.

**Growing the knowledge base (`:NovibeConsult` + "snapshot")**
- Open a consult session with `:NovibeConsult`. Explore the codebase, ask questions, investigate dependencies.
- Say **"snapshot"** whenever you discover something worth keeping. The AI writes it to the right `topics/<area>/` file with the current commit hash for staleness tracking.
- The knowledge base grows lazily as you touch areas — no need to document everything upfront.

**Switching models (`:NovibeProfile`)**
- Run `:NovibeProfile` to open a two-step picker: choose a slot (Act, Consult, or Agent), then a profile. Each slot persists independently.
- Profiles are defined in your `setup()` call with `provider`, `model`, and `effort`. No active profile = CLI defaults.
- Use a fast/cheap profile for routine fills and a powerful profile for complex consult sessions.

Finally, tell the user:
- Decide how to track `.no_vibe/` in git — that is up to you based on your team setup
- They can add more topic folders at any time — update `topics/index.md` to register them

## Step 5 — Personal config

Ask the user:

> **Is there any personal config you want to add to novibe?** (e.g. task management behavior, language preferences, agent session rules)

If yes: "If you have a personal novibe config seeder, run `:NovibeAgent` and point it at the seeder file. It will create or update `.no_vibe/config.md` with your preferences. If you don't have a seeder yet, there's an example at `examples/my-novibe-config-seeder.md` in the novibe.nvim repo."

If no: skip this step.

Do not generate `config.md` yourself — it is personal and seeder-driven.
