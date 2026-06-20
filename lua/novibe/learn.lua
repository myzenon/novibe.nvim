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
  local has_diff = original ~= nil and original ~= current
  local has_reason = reason and reason ~= ""

  if not has_diff and not has_reason then
    vim.notify(
      "novibe: nothing to teach — provide a #teach reason, or edit a recent fill to create a diff",
      vim.log.levels.WARN
    )
    return
  end

  local entry = {
    current  = current,
    reason   = has_reason and reason or nil,
    filename = vim.fn.fnamemodify(filename, ":."),
    at       = os.date("%Y-%m-%d %H:%M"),
  }
  if has_diff then entry.original = original end

  local diffs = load_diffs()
  table.insert(diffs, entry)
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

You will receive existing rule files and new evidence with reasons.
Evidence comes in two forms:
- Diffs: original AI output + the user's corrected version (the user edited a fill)
- Notes: a user code sample + an explicit teaching reason (no AI involvement — direct instruction)

Treat both as equally valid signal. Diffs imply the rule from the change; notes state it via the reason and example.

Your job:
- Analyze the evidence to understand the user's coding preferences
- Decide which topic file each rule belongs to (e.g. learned-style.md, learned-react.md, learned-loops.md)
- Rewrite affected files cleanly — merge, deduplicate, resolve contradictions
- Create new topic files when a new theme emerges
- Omit files you did not change

Each file uses NO_VIBE.md section format:
  ## always       — rule applies to every file
  ## *.tsx        — rule applies only to matching files

Support count tracking (CRITICAL):
- Every rule line MUST end with an HTML comment of the form <!-- n=N --> where N is the number of distinct evidence items supporting this rule.
- When you preserve an existing rule unchanged, KEEP its existing N value.
- When new evidence reinforces an existing rule, INCREMENT its N (e.g. n=4 -> n=5).
- When you create a new rule from M items, set n=M.
- When you merge two rules into one, sum their N values.
- Format: `- rule text <!-- n=3 -->`

Respond with ONLY a valid JSON object — no prose, no markdown fences:
{
  "learned-style.md": "## always\n- prefer for-loops over .map() <!-- n=5 -->\n- early return over nested if <!-- n=2 -->\n",
  "learned-react.md": "## *.tsx\n- named function over arrow <!-- n=3 -->\n"
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

  table.insert(parts, string.format("New evidence to incorporate (%d):", #diffs))
  for i, diff in ipairs(diffs) do
    local kind = diff.original and "Diff" or "Note"
    table.insert(parts, string.format("\n--- %s %d (%s, %s) ---", kind, i, diff.filename or "unknown", diff.at or ""))
    if diff.original then
      table.insert(parts, "AI wrote:")
      table.insert(parts, diff.original)
      table.insert(parts, "User changed to:")
      table.insert(parts, diff.current)
    elseif diff.current then
      table.insert(parts, "User code (direct teaching — no AI diff):")
      table.insert(parts, diff.current)
    end
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

    -- Distill expects a filename→content map, not the novibe schema.
    -- Parse independently: strip any prose before/after JSON, unwrap the
    -- provider envelope (claude: outer.result),
    -- strip markdown fences.
    local raw = vim.trim(result.stdout or "")
    local first = raw:find("{")
    local last  = nil
    if first then
      local pos = first
      while true do
        local found = raw:find("}", pos, true)
        if not found then break end
        last = found
        pos = found + 1
      end
    end
    if first and last then
      raw = raw:sub(first, last)
    end
    local ok1, outer = pcall(vim.json.decode, raw)
    if ok1 and type(outer) == "table" then
      if type(outer.result) == "string" then
        raw = vim.trim(outer.result)
      elseif type(outer.response) == "string" then
        raw = vim.trim(outer.response)
      end
    end
    raw = raw:gsub("^```[%w]*\n?", ""):gsub("\n?```%s*$", "")
    raw = vim.trim(raw)

    local ok2, files = pcall(vim.json.decode, raw)
    if not ok2 or type(files) ~= "table" then
      vim.notify("novibe: distill response parse failed", vim.log.levels.ERROR)
      return
    end

    -- Fallback: if Claude replied in novibe schema (memory override), the map may be in .code
    local has_learned_key = false
    for k in pairs(files) do
      if k:match("^learned%-") then has_learned_key = true; break end
    end
    if not has_learned_key and type(files.code) == "string" then
      local ok3, extracted = pcall(vim.json.decode, files.code)
      if ok3 and type(extracted) == "table" then files = extracted end
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
