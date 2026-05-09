local M = {}

local function find_no_vibe_dir()
  local dir = vim.fn.getcwd()
  for _ = 1, 10 do
    if vim.fn.filereadable(dir .. "/NO_VIBE.md") == 1
    or vim.fn.isdirectory(dir .. "/.no_vibe") == 1 then
      return dir .. "/.no_vibe"
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return vim.fn.getcwd() .. "/.no_vibe"
end

local function diffs_path()
  return find_no_vibe_dir() .. "/diffs.json"
end

local function load_diffs()
  local path = diffs_path()
  if vim.fn.filereadable(path) == 0 then return {} end
  local ok, diffs = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return ok and diffs or {}
end

local function save_diffs(diffs)
  local dir = find_no_vibe_dir()
  if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
  vim.fn.writefile({ vim.json.encode(diffs) }, diffs_path())
end

local function has_learned_rules()
  local dir = find_no_vibe_dir()
  local files = vim.fn.glob(dir .. "/learned-*.md", false, true)
  for _, path in ipairs(files) do
    if vim.trim(table.concat(vim.fn.readfile(path), "\n")) ~= "" then
      return true
    end
  end
  return false
end

local function effective_threshold(configured)
  if not configured then return nil end
  return has_learned_rules() and configured or 1
end

function M.teach(original, current, reason, filename, provider, bin, auto_after, profile)
  if original == current then
    vim.notify("novibe: no changes detected — nothing to teach", vim.log.levels.WARN)
    return
  end

  local diffs = load_diffs()
  table.insert(diffs, {
    original = original,
    current  = current,
    reason   = reason ~= "" and reason or nil,
    filename = vim.fn.fnamemodify(filename, ":."),
    at       = os.date("%Y-%m-%d %H:%M"),
  })
  save_diffs(diffs)

  local threshold = effective_threshold(auto_after)
  vim.notify(
    string.format("novibe: diff saved (%d/%s accumulated)", #diffs, threshold and tostring(threshold) or "∞"),
    vim.log.levels.INFO
  )

  if threshold and #diffs >= threshold then
    vim.notify(
      string.format("novibe: %d diff(s) reached threshold — distilling…", #diffs),
      vim.log.levels.INFO
    )
    M.extract(provider, bin, profile)
  end
end

function M.extract(provider, bin, profile)
  local diffs = load_diffs()
  if #diffs == 0 then
    vim.notify("novibe: no accumulated diffs to distill", vim.log.levels.WARN)
    return
  end

  local dir = find_no_vibe_dir()

  -- read all existing learned-*.md files
  local existing = {}
  for _, path in ipairs(vim.fn.glob(dir .. "/learned-*.md", false, true)) do
    local name = vim.fn.fnamemodify(path, ":t")
    existing[name] = table.concat(vim.fn.readfile(path), "\n")
  end

  local parts = {
    [[You organize coding style rules into topic-focused files.

You will receive existing rule files and new code diffs with reasons.

Your job:
- Analyze diffs and reasons to understand the user's coding preferences
- Decide which topic file each rule belongs to (e.g. learned-style.md, learned-react.md, learned-loops.md)
- Rewrite affected files cleanly — merge, deduplicate, resolve contradictions
- Create new topic files when a new theme emerges
- Omit files you did not change

Each file uses NO_VIBE.md section format:
  ## always       — rule applies to every file
  ## *.tsx        — rule applies only to matching files

Respond with ONLY a valid JSON object — no prose, no markdown fences:
{
  "learned-style.md": "## always\n- rule\n",
  "learned-react.md": "## *.tsx\n- rule\n"
}

Filenames must match: learned-<topic>.md]],
    "",
  }

  if next(existing) then
    table.insert(parts, "Existing rule files:")
    for name, content in pairs(existing) do
      table.insert(parts, string.format("\n--- %s ---\n%s", name, content))
    end
    table.insert(parts, "")
  end

  table.insert(parts, string.format("New diffs to incorporate (%d):", #diffs))
  for i, diff in ipairs(diffs) do
    table.insert(parts, string.format("\n--- Diff %d (%s, %s) ---", i, diff.filename or "unknown", diff.at or ""))
    table.insert(parts, "AI wrote:")
    table.insert(parts, diff.original)
    table.insert(parts, "User changed to:")
    table.insert(parts, diff.current)
    if diff.reason then
      table.insert(parts, "Reason: " .. diff.reason)
    end
  end

  local prompt = table.concat(parts, "\n")
  local cmd = provider.build_cmd(bin, prompt, {
    profile      = profile,
    bare         = false,
    use_continue = false,
    session_id   = nil,
  })

  vim.system(cmd, { text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 or vim.trim(result.stdout or "") == "" then
      vim.notify("novibe: distill failed — " .. vim.trim(result.stderr or ""), vim.log.levels.ERROR)
      return
    end

    -- distill prompt asks for a JSON filename→content map (not the novibe schema).
    -- The provider parser parses the inner JSON; for a filename map response it
    -- returns that map directly as the "response" table.
    local files = provider.parse_output(result.stdout)
    if type(files) ~= "table" then
      vim.notify("novibe: distill response parse failed", vim.log.levels.ERROR)
      return
    end

    if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end

    local written = {}
    for filename, content in pairs(files) do
      if filename:match("^learned%-[%w%-]+%.md$") then
        vim.fn.writefile(vim.split(vim.trim(content), "\n", { plain = true }), dir .. "/" .. filename)
        table.insert(written, filename)
      end
    end

    if #written == 0 then
      vim.notify(
        "novibe: distill returned no valid filenames — diffs preserved, please retry",
        vim.log.levels.ERROR
      )
      return
    end

    save_diffs({})
    vim.notify(
      string.format("novibe: %d diff(s) distilled → %s", #diffs, table.concat(written, ", ")),
      vim.log.levels.INFO
    )
  end))
end

return M
