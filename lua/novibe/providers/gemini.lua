local M = {}

M.name = "gemini"
M.streaming = true

function M.find_bin()
  local found = vim.fn.exepath("gemini")
  if found ~= "" then return found end
  for _, path in ipairs({
    vim.fn.expand("~/.local/bin/gemini"),
    "/usr/local/bin/gemini",
    "/opt/homebrew/bin/gemini",
  }) do
    if vim.fn.filereadable(path) == 1 then return path end
  end
  return nil
end

-- Called once per stdout data chunk in streaming mode.
-- Returns text from assistant delta message events.
function M.parse_chunk(data)
  local parts = {}
  for _, line in ipairs(vim.split(data, "\n", { plain = true })) do
    if line ~= "" then
      local ok, ev = pcall(vim.json.decode, line)
      if ok and type(ev) == "table" and ev.type == "message"
         and ev.role == "assistant" and ev.delta == true
         and type(ev.content) == "string" then
        table.insert(parts, ev.content)
      end
    end
  end
  return table.concat(parts)
end

-- opts: { profile, session_id, stream }
-- gemini has no --bare or --continue; session continuity uses --session-id.
-- Workspace must be trusted (run `gemini` interactively once and trust the dir,
-- or set GEMINI_CLI_TRUST_WORKSPACE=true).
function M.build_cmd(bin, prompt, opts)
  local fmt = opts.stream and "stream-json" or "json"
  local cmd = { bin, "--output-format", fmt }
  if opts.profile and opts.profile.model then
    vim.list_extend(cmd, { "--model", opts.profile.model })
  end
  if opts.session_id and opts.session_id ~= "" then
    vim.list_extend(cmd, { "--session-id", opts.session_id })
  end
  vim.list_extend(cmd, { "--prompt", prompt })
  return cmd
end

local function unwrap_and_parse(text)
  text = text:gsub("^```[%w]*\n?", ""):gsub("\n?```%s*$", "")
  text = vim.trim(text)
  local ok, parsed = pcall(vim.json.decode, text)
  if ok and type(parsed) == "table" then return parsed end
  local ji, jj = text:find("{"), nil
  if ji then
    local pos = ji
    while true do
      local found = text:find("}", pos, true)
      if not found then break end
      jj = found; pos = found + 1
    end
  end
  if ji and jj then
    local ok2, r = pcall(vim.json.decode, text:sub(ji, jj))
    if ok2 and type(r) == "table" then return r end
  end
  return { code = text, changes = {}, message = nil, done = true }
end

-- Handles both --output-format json (single object) and stream-json (delta events).
function M.parse_output(stdout)
  local raw = vim.trim(stdout)

  -- stream-json path: lines with type field (init / message / result events)
  local first_line = raw:match("^[^\n]+")
  local ok0, first_ev = pcall(vim.json.decode, first_line or "")
  if ok0 and type(first_ev) == "table" and first_ev.type then
    local text_parts = {}
    local session_id, stats = nil, nil
    for _, line in ipairs(vim.split(raw, "\n", { plain = true })) do
      if line ~= "" then
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" then
          session_id = session_id or ev.session_id
          if ev.type == "message" and ev.role == "assistant" and ev.delta == true then
            table.insert(text_parts, ev.content or "")
          elseif ev.type == "result" then
            stats = ev.stats
          end
        end
      end
    end
    local response = unwrap_and_parse(vim.trim(table.concat(text_parts)))
    local in_tokens, out_tokens = nil, nil
    if stats then
      in_tokens  = stats.input_tokens
      out_tokens = stats.output_tokens
    end
    return response, {
      cost_usd = nil, input_tokens = in_tokens, output_tokens = out_tokens,
      context_window = nil, session_id = session_id,
    }
  end

  -- json path: single object { session_id, response, stats }
  local ok, outer = pcall(vim.json.decode, raw)
  if not ok or type(outer) ~= "table" then
    return { code = raw, changes = {}, message = nil, done = true }, nil
  end

  local response = unwrap_and_parse(type(outer.response) == "string" and outer.response or "")

  local in_tokens, out_tokens = nil, nil
  if outer.stats and outer.stats.models then
    for _, m in pairs(outer.stats.models) do
      if m.tokens then
        in_tokens  = (in_tokens  or 0) + (m.tokens.input      or 0)
        out_tokens = (out_tokens or 0) + (m.tokens.candidates or 0)
      end
    end
  end

  return response, {
    cost_usd = nil, input_tokens = in_tokens, output_tokens = out_tokens,
    context_window = nil, session_id = outer.session_id,
  }
end

return M
