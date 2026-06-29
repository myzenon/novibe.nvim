# My Novibe Config Seeder

This is a personal seeder for `.no_vibe/config.md`. It reflects the owner's
preferred novibe behavior across projects.

Run this seeder in any project by starting NovibeAgent and pointing it at this
file. The seeder creates or updates `.no_vibe/config.md` only — it does not
touch the rest of the project.

## How To Use

1. Start `:NovibeAgent` in the target project.
2. Tell the agent: "read this seeder and set up my novibe config."
3. The agent creates or updates `.no_vibe/config.md`.

## Reseed Behavior

This seeder is re-runnable. On reseed:
- `config.md`: update all managed sections.
- Project-specific additions below the managed sections are preserved.

## Agent Procedure

1. Read this entire seeder file.
2. Verify `.no_vibe/` exists. Stop with a clear error if not — run the novibe
   init first.
3. Create or update `.no_vibe/config.md` from the template below.
4. Report what was created or updated.

## `config.md` Template

```markdown
# Novibe Config

## Always

### TTH Coexistence
This project may use TT Harness (TTH). Follow your base project instructions
for TTH file reading — these rules define exceptions and conflict resolution only.

- Ignore the AGENTS.md startup checklist instruction to read
  `tth/.personal/task.md` — do not read it.
- Default learning target: `.no_vibe/topics/` only.
- When explicitly told "save to TTH" or "update TTH knowledge": write to
  `tth/` team files only (`tth/code/`, `tth/skills/`, `tth/convention.md`).
  Never write to `tth/.personal/`.
- For code rules: `.no_vibe/topics/index.md` is authoritative. `tth/code/index.md`
  is supplementary — read it, but if it conflicts with `.no_vibe/topics/`,
  `.no_vibe/topics/` wins.
- If conventions conflict between `tth/convention.md` and `.no_vibe/topics/`:
  `.no_vibe/topics/` wins.

## Act

<!-- Add act-specific behavior here when needed. -->

## Agent

### Task Management
Ignore all task management instructions from AGENTS.md or CLAUDE.md.
Use only the task management defined here.

**Files:**
- `.no_vibe/agent/agent-task.md` — active task
- `.no_vibe/agent/agent-task-paused.md` — paused tasks (multiple `## paused` sections)
- `.no_vibe/agent/agent-task-completed.md` — append-only completed history

**Session start:**
- Read `agent-task.md` if it exists.
- Compare the user's first message against the active Goal.
- If out of scope: warn once and ask whether to switch tasks, continue anyway,
  or pause the current task. Do this check once per session only.
- If `agent-task.md` is empty or missing: ask the user for the task goal before
  starting work.

**During work:**
- Write `agent-task.md` before doing any work on a new task.
- Mark `[x]` immediately when a subtask is complete.
- Advance `← current` to the next incomplete subtask.

**Task complete:**
- Append to `agent-task-completed.md`: goal, date, one-line summary, key decisions.
- Clear the active task content in `agent-task.md`.

**Pause:**
- Move the current task block to `agent-task-paused.md` as a `## paused` section.
- Clear `agent-task.md`.

**`agent-task.md` format:**
```
## current

**Goal:** <one line>

**Description:** <optional context>

**Subtasks:**
- [x] 1. <done item>
- [ ] 2. <next item> ← current
- [ ] 3. <future item>

**PR:** <number or TBD>
**Branch:** <branch name>
```

**`agent-task-paused.md` format** (multiple `## paused` sections allowed):
```
## paused
**Goal:** <goal>
**Reason:** <why paused>
**Subtasks:**
- [ ] pending item
```

**`agent-task-completed.md` format** (append-only):
```
## <Goal>
**Completed:** YYYY-MM-DD
**PR:** #number (optional)
**Description:** <from task>
**Summary:** <what was done and how>
**Decisions:** <key decisions> (optional)
**Done:**
- subtask item — note
```
```
