local M = {}

M.name = "claude"

function M.find_bin()
  local found = vim.fn.exepath("claude")
  if found ~= "" then return found end
  for _, path in ipairs({
    vim.fn.expand("~/.local/bin/claude"),
    "/usr/local/bin/claude",
    "/opt/homebrew/bin/claude",
  }) do
    if vim.fn.filereadable(path) == 1 then return path end
  end
  return nil
end

-- opts: { profile, bare, use_continue }
function M.build_cmd(bin, prompt, opts)
  local cmd = { bin }
  if opts.bare then table.insert(cmd, "--bare") end
  if opts.profile and opts.profile.model then
    vim.list_extend(cmd, { "--model", opts.profile.model })
  end
  if opts.profile and opts.profile.effort then
    vim.list_extend(cmd, { "--effort", opts.profile.effort })
  end
  if opts.use_continue then table.insert(cmd, "--continue") end
  vim.list_extend(cmd, { "--output-format", "json", "--print", prompt })
  return cmd
end

-- Try to extract a JSON object from a string that may have leading/trailing prose.
local function extract_json(s)
  s = vim.trim(s)
  -- strip markdown fences
  s = s:gsub("^```[%w]*\n?", ""):gsub("\n?```%s*$", "")
  s = vim.trim(s)
  local ok, parsed = pcall(vim.json.decode, s)
  if ok and type(parsed) == "table" then return parsed end
  -- find first { to last } and try that substring
  local i = s:find("{")
  local last_j = nil
  local pos = 1
  while true do
    local found = s:find("}", pos, true)
    if not found then break end
    last_j = found
    pos = found + 1
  end
  if i and last_j and last_j >= i then
    local ok2, parsed2 = pcall(vim.json.decode, s:sub(i, last_j))
    if ok2 and type(parsed2) == "table" then return parsed2 end
  end
  return nil
end

-- Returns response, usage. Usage may be nil if envelope missing.
function M.parse_output(stdout)
  local raw = vim.trim(stdout)
  local ok, outer = pcall(vim.json.decode, raw)
  if not ok then
    local extracted = extract_json(raw)
    if extracted then return extracted, nil end
    return { code = raw, changes = {}, message = nil, done = true }, nil
  end

  -- plain novibe JSON (no envelope)
  if outer.result == nil then
    return outer, nil
  end

  local usage = {
    cost_usd       = outer.total_cost_usd,
    input_tokens   = outer.usage and outer.usage.input_tokens,
    output_tokens  = outer.usage and outer.usage.output_tokens,
    context_window = nil,
    session_id     = nil,
  }
  if outer.modelUsage then
    for _, mu in pairs(outer.modelUsage) do
      if mu.contextWindow then usage.context_window = mu.contextWindow; break end
    end
  end

  local inner_raw = type(outer.result) == "string" and outer.result or ""
  local ok2, response = pcall(vim.json.decode, inner_raw)
  if not ok2 then
    response = extract_json(inner_raw) or { code = inner_raw, changes = {}, message = nil, done = true }
  end

  return response, usage
end

return M
