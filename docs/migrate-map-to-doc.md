# novibe.nvim — migrate map-* to doc-*

The `.no_vibe/map-*.md` prefix has been renamed to `doc-*.md` to better reflect its purpose: general project documentation (how features work, module descriptions, call chains, structural knowledge) rather than just dependency graphs.

## Migration steps

1. Find all existing `map-*.md` files in this project's `.no_vibe/` directory.

2. Rename each one: `map-<area>.md` → `doc-<area>.md`.
   - Use `git mv .no_vibe/map-<area>.md .no_vibe/doc-<area>.md` so the rename is tracked in git history.
   - Example: `git mv .no_vibe/map-auth.md .no_vibe/doc-auth.md`

3. Check `CLAUDE.md` and `AGENTS.md` for any references to `map-*.md` and update them to `doc-*.md`.

4. Check `.no_vibe/convention-*.md` for any references to `map-*.md` and update them.

5. Confirm no `map-*.md` files remain: `ls .no_vibe/map-*.md 2>/dev/null` should return nothing.

## No content changes needed

The file format, section headers, and `<!-- last-verified: HASH -->` comments are unchanged — only the filename prefix changes. Existing content is valid as-is.
