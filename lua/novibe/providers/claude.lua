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

-- Returns response, usage. Usage may be nil if envelope missing.
function M.parse_output(stdout)
  local raw = vim.trim(stdout)
  local ok, outer = pcall(vim.json.decode, raw)
  if not ok then
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
    response = { code = inner_raw, changes = {}, message = nil, done = true }
  end

  return response, usage
end

return M
