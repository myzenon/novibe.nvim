local M = {}

M.name = "claude"
M.streaming = true

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

-- Called once per stdout data chunk in streaming mode.
-- Returns text extracted from content_block_delta events (deltas, not cumulative).
function M.parse_chunk(data)
  local parts = {}
  for _, line in ipairs(vim.split(data, "\n", { plain = true })) do
    if line ~= "" then
      local ok, ev = pcall(vim.json.decode, line)
      if ok and type(ev) == "table" and ev.type == "stream_event"
         and type(ev.event) == "table"
         and ev.event.type == "content_block_delta"
         and type(ev.event.delta) == "table"
         and ev.event.delta.type == "text_delta"
         and type(ev.event.delta.text) == "string" then
        table.insert(parts, ev.event.delta.text)
      end
    end
  end
  return table.concat(parts)
end

-- opts: { profile, bare, use_continue, stream }
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
  if opts.stream then
    vim.list_extend(cmd, { "--output-format", "stream-json", "--include-partial-messages", "--verbose", "--print", prompt })
  else
    vim.list_extend(cmd, { "--output-format", "json", "--print", prompt })
  end
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

local function parse_envelope(outer)
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
  local ok, response = pcall(vim.json.decode, inner_raw)
  if not ok then
    response = extract_json(inner_raw) or { code = inner_raw, changes = {}, message = nil, done = true }
  end
  return response, usage
end

-- Returns response, usage. Handles both --output-format json (single object)
-- and --output-format stream-json (newline-delimited events with a result line).
function M.parse_output(stdout)
  local raw = vim.trim(stdout)

  -- stream-json path: scan for the result event line
  if raw:find('"type"', 1, true) then
    for _, line in ipairs(vim.split(raw, "\n", { plain = true })) do
      if line ~= "" then
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" and ev.type == "result" then
          return parse_envelope(ev)
        end
      end
    end
  end

  -- json path: single JSON object
  local ok, outer = pcall(vim.json.decode, raw)
  if not ok then
    local extracted = extract_json(raw)
    if extracted then return extracted, nil end
    return { code = raw, changes = {}, message = nil, done = true }, nil
  end
  if outer.result == nil then
    return outer, nil
  end
  return parse_envelope(outer)
end

return M
