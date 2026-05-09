local M = {}

-- Unwrap --output-format json outer envelope and parse inner novibe JSON.
-- Returns (response, usage|nil).
function M.parse_claude_output(stdout)
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
    cost_usd      = outer.total_cost_usd,
    input_tokens  = outer.usage and outer.usage.input_tokens,
    output_tokens = outer.usage and outer.usage.output_tokens,
    context_window = nil,
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
