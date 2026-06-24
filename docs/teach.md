# Teaching novibe your style

The teach→distill→promote pipeline is how novibe learns your preferences from real code changes, not hand-written rules. Instead of writing a convention file upfront, you show novibe what you prefer by example — it extracts the rule itself.

---

## The idea

Every time you correct a fill — shortening it, swapping a loop style, changing a naming pattern — that correction is a data point. `#teach` captures it. Enough data points get distilled into a rule. Enough rule reinforcement gets the rule promoted to a convention.

Three stages:

```
#teach diffs  →  act/learned-*.md (staged)  →  topics/<area>/rule.md (canonical)
   (evidence)         (AI's hypothesis)            (committed rule)
```

---

## Two ways to teach

### Diff mode — after a fill

The most powerful mode. After a fill, edit the result to your preference, re-select the same block, and run `:NovibeAct` with `#teach <reason>`:

1. Run `:NovibeAct` on a skeleton → fill streams in → press `<CR>` to apply
2. Edit the result — swap the loop style, remove a `console.log`, rename something
3. Re-select the same block (`gv` restores the last visual selection)
4. Run `:NovibeAct` → type `#teach prefer for loop over map` → `:w`

novibe captures the diff between the fill's output and your edited version:

```javascript
// fill produced:
const names = users.map(u => u.name)

// you changed it to:
const names = []
for (const u of users) {
  names.push(u.name)
}
```

This diff is the evidence: "given that input, the user changed X to Y." Distillation extracts "prefer for-loops over `.map()`" from it.

### Note mode — direct rule capture

When you notice a pattern in existing code — or want to declare a rule without a fill — select any representative block and run `#teach` on it:

```
#teach this is the canonical error handling pattern in this project
#teach auth always goes through AuthService, never direct db calls
```

No diff here — the selection itself is the evidence. Distillation treats it as a direct rule note with full weight.

**Use note mode when:**
- You're establishing a rule before you've had fills to correct
- You notice existing code following a pattern worth formalizing
- The fill was correct but you want to reinforce the pattern anyway

### From Act2 — integrated teach with `t`

`:NovibeAct2` builds teach directly into the review flow. No re-selection, no `#teach` prefix:

1. Run `:NovibeAct2` on a skeleton → AI code appears in-buffer with virt_line review controls
2. Press `<leader>t` (default) — code is accepted and edit mode activates. Virt_lines change to: `edit in scope · <leader>t done · U cancel`
3. Edit the AI code in-place — swap a loop style, rename, simplify
4. Press `<leader>t` again — a reason float opens
5. Type your reason (plain text, no `#teach`) → `:w` to submit
6. novibe computes the diff between the AI's original output and your edited version, then saves it

**If you press `t` twice without editing**, the code is saved as a note-mode entry (no diff, reason only) — same as Note mode in `:NovibeAct`.

The out-of-scope scratch window stays open during teach so you can see what imports/types still need manual updates.

### From the chat — capture feedback as a rule

`#teach <reason>` also works inside the fill-preview chat. Type it after the marker and `:w` — the reason is captured as a note-mode teach entry; no AI call, no change to the current question:

```
[1/2] In-scope code:
function load(id) {
  return db.query(`SELECT * FROM users WHERE id = ${id}`)
}

── <CR> accept  ·  type feedback + :w to send ──
#teach never interpolate into raw SQL — use parameterized queries
```

Use this when you're reviewing AI output and notice a rule worth keeping, but don't want to derail the current revision. Pure note mode — no diff captured, because chat feedback is verbal (you describe the rule in words rather than writing the corrected code yourself).

---

## Distillation

Captured evidence accumulates in `.no_vibe/diffs.json` (don't edit this; add it to `.gitignore`). When enough evidence accumulates, novibe automatically distills it into `act/learned-*.md` topic files.

### Auto-distill threshold

| Project state | Threshold |
|---|---|
| Fresh (no `act/learned-*.md` yet) | **1** — first `#teach` triggers distillation immediately |
| Established | `learn.auto_extract_after` (default **3**) |

Force distillation at any time: `:NovibeDistill`

Disable auto-distillation: `learn = { auto_extract_after = nil }` in setup.

### What distillation does

The prompt sends all accumulated diffs to the AI alongside any existing `act/learned-*.md` files. The AI:

1. Groups related evidence by topic
2. Extracts a clean rule from each diff or note
3. Merges with existing learned rules — deduplicates, strengthens supported ones
4. Splits output into topic files: `act/learned-style.md`, `act/learned-react.md`, etc.

Each rule in the output carries a support count:

```markdown
## always
- prefer for-loops over .map() <!-- n=4 -->
- always use early return <!-- n=2 -->
- no console.log in filled code <!-- n=1 -->
```

`n` = distinct diffs that back this rule. After distillation, `diffs.json` is cleared.

**Do not edit `act/learned-*.md` by hand** — future distillations regenerate and merge them, overwriting your edits.

---

## The staging area

`act/learned-*.md` files are the AI's working hypothesis about your style:

- **Regenerated** by every distillation — merged with new evidence, not replaced wholesale
- **Topic-split** by the AI — naming and topic grouping are decided at distillation time
- **Filtered by filename** before being sent to the model — a hooks rule never reaches a service file
- **Browsable** via `:NovibeKB` → Learned (act)

Think of `act/learned-*.md` as "rules the AI believes but hasn't confirmed with you yet." You confirm them by promoting.

---

## Promotion

Promotion graduates a rule from staging (`act/learned-*.md`) to canonical (`topics/<area>/rule.md`).

| File | Role |
|---|---|
| `act/learned-*.md` | Mutable staging. AI's hypothesis. Regenerated by distillation. |
| `topics/<area>/rule.md` | Canonical. Committed rules. Distillation never touches them. |

### When to promote

`n >= 3` is a good signal — the rule has been reinforced by at least 3 distinct corrections. `n = 1` is premature. `n = 8` is overdue.

### Running `:NovibePromote`

The plugin reads all `act/learned-*.md` and existing `topics/*/rule.md` files, asks the model to identify mature rules and propose where they should land, then opens the chat review panel:

```
[1/3] .no_vibe/topics/style/rule.md  [create]
│  Mature style rules graduated from act/learned-style.md
│
       + ## always
       + - prefer for-loops over .map()
       + - always use early return
└──────────────────────────────────────────────────

[2/3] .no_vibe/act/learned-style.md  [replace]
│  Remove promoted rules; keep premature ones
│
  42   - prefer for-loops over .map() <!-- n=8 -->
  43   - always use early return <!-- n=4 -->
       + (only "no semicolons <!-- n=1 -->" remains)
└──────────────────────────────────────────────────
```

Interact exactly like the fill review queue:

| Input | What happens |
|---|---|
| `<CR>` | Apply this change and advance |
| `s` | Skip this change |
| `lgtm` / `ok` + `:w` | Apply all remaining changes |
| `"put style rules in topics/style/rule.md"` + `:w` | AI revises the destination |
| `"also promote no semicolons"` + `:w` | AI adds the rule |
| `q` | Cancel — nothing is written |

**Destination topic is your call.** The AI picks a sensible default based on the learned file name; revise via chat if you want it somewhere else.

After promotion, the rule loses its `<!-- n=N -->` annotation — topic rule files are canonical, the count is no longer needed. The rule is also removed from `act/learned-*.md`. Future distillations won't re-add it because the model sees the topic files as context.

---

## Full lifecycle

```
1. You fill code with :NovibeAct
2. You edit the fill to match your preference
3. gv → :NovibeAct → #teach prefer X over Y
                ↓
        .no_vibe/diffs.json                 ← evidence accumulates
                ↓  (threshold reached, or :NovibeDistill)
        .no_vibe/act/learned-style.md
        - prefer X over Y  <!-- n=1 -->
                ↓  (more diffs reinforce the rule)
        .no_vibe/act/learned-style.md
        - prefer X over Y  <!-- n=4 -->
                ↓  (:NovibePromote, n >= 3)
        .no_vibe/topics/style/rule.md
        - prefer X over Y              ← canonical, count stripped
```

---

## Tips

**Teach vs write directly**
If you already know the rule and it's firm ("always use named exports"), write it in `topics/<area>/rule.md` directly. Use `#teach` for preferences you're still observing — let evidence accumulate before committing.

**Reason strings matter**
`#teach prefer for loop over map` is better than `#teach fix`. A good reason becomes the rule label during distillation.

**Note mode for architecture rules**
When reading code you notice "all auth goes through `AuthService`" — select a representative call site, `#teach auth always goes through AuthService, never direct db calls`. This surfaces in the next distillation as a high-priority rule.

**How often to promote**
Run `:NovibePromote` periodically — weekly on an active project. It's safe to run anytime; if nothing is mature (`n < 3`), the model will say so and propose nothing.

**Personal preferences**
Put personal preferences in `config.md` (seeder-driven, gitignore it). Project team rules go in `topics/*/rule.md` and get committed.
