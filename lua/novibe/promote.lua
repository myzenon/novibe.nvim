local no_vibe = require("novibe.no_vibe")
local chat    = require("novibe.chat")

local M = {}

local PROMOTE_PROMPT = [[You help promote mature staged rules from `.no_vibe/learned-*.md` files into canonical `.no_vibe/convention-*.md` files.

Each rule line has a support count `<!-- n=N -->` indicating how many distinct user diffs reinforced it. Higher N = more evidence the rule reflects real preference.

Your job:
- Identify rules with strong support (n >= 3 is a reasonable bar; use judgment for n=2 if the rule is unambiguous; do not promote n=1 unless the user asks).
- Choose a destination convention file for each promoted rule. Default mapping: `learned-<topic>.md` -> `convention-<topic>.md`. If a matching convention file already exists, append the rule under the correct section header.
- Generate two kinds of changes per promoted rule:
  1. Add the rule to a `convention-*.md` file (create new file or append to existing section). Strip the `<!-- n=N -->` annotation — conventions are canonical, the count served its purpose.
  2. Remove the rule from its `learned-*.md` file. Keep the file (with remaining rules) if anything is left; remove the entire section if it becomes empty.
- Do NOT promote rules with low support. Leave them in learned for now.
- Do NOT modify or duplicate rules already present in convention files.

Use the standard novibe `changes[]` schema. For each change, use the `find` field to anchor existing content exactly.

Respond ONLY in JSON:
{
  "message": "Brief summary of what you propose to promote and why.",
  "changes": [
    { "file": ".no_vibe/convention-style.md", "description": "...", "action": "replace|insert_after|insert_before", "find": "...", "replace": "..." }
  ],
  "done": false
}

Set "done": false initially so the user can review.]]

local function read_file(path)
  if vim.fn.filereadable(path) == 0 then return nil end
  return table.concat(vim.fn.readfile(path), "\n")
end

function M.promote(provider, bin, profile)
  local found = no_vibe.discover()
  if not found then
    vim.notify("novibe: no .no_vibe/ directory found in this project", vim.log.levels.WARN)
    return
  end

  if #found.learned == 0 then
    vim.notify("novibe: no learned-*.md files yet — run :NovibeAct with #teach first", vim.log.levels.WARN)
    return
  end

  local parts = { PROMOTE_PROMPT, "" }

  table.insert(parts, "Current learned files (staged rules with support counts):")
  for _, path in ipairs(found.learned) do
    local content = read_file(path)
    if content then
      table.insert(parts, string.format("\n--- %s ---\n%s", vim.fn.fnamemodify(path, ":."), content))
    end
  end

  if #found.conventions > 0 then
    table.insert(parts, "\nExisting convention files (already canonical — do not duplicate):")
    for _, path in ipairs(found.conventions) do
      local content = read_file(path)
      if content then
        table.insert(parts, string.format("\n--- %s ---\n%s", vim.fn.fnamemodify(path, ":."), content))
      end
    end
  else
    table.insert(parts, "\nNo existing convention files — you may create new ones.")
  end

  if found.novibe_md then
    local content = read_file(found.novibe_md)
    if content then
      table.insert(parts, string.format("\nNO_VIBE.md (also canonical):\n%s", content))
    end
  end

  local prompt = table.concat(parts, "\n")

  vim.notify("novibe: analyzing learned rules for promotion…", vim.log.levels.INFO)

  local cmd = provider.build_cmd(bin, prompt, {
    profile      = profile,
    bare         = false,
    use_continue = false,
    session_id   = nil,
  })

  vim.system(cmd, { text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 or vim.trim(result.stdout or "") == "" then
      vim.notify("novibe: promote failed — " .. vim.trim(result.stderr or ""), vim.log.levels.ERROR)
      return
    end

    local response = provider.parse_output(result.stdout)
    if type(response) ~= "table" then
      vim.notify("novibe: promote response parse failed", vim.log.levels.ERROR)
      return
    end

    local changes = type(response.changes) == "table" and response.changes or {}
    local has_changes = #changes > 0
    local has_message = response.message and response.message ~= vim.NIL

    if not (has_changes or has_message) then
      vim.notify("novibe: nothing mature enough to promote yet — keep teaching", vim.log.levels.INFO)
      return
    end

    -- The chat side panel handles review/revise/apply just like out-of-scope
    -- changes. Promotion uses the same schema, so it's the same machinery.
    chat.open(response, {
      bin        = bin,
      provider   = provider,
      session_id = nil,  -- promotion is a fresh, standalone exchange
    })
  end))
end

return M
