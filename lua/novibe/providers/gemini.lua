local M = {}

M.name = "gemini"

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

-- opts: { profile, session_id }
-- gemini has no --bare or --continue; session continuity uses --session-id.
-- Workspace must be trusted (run `gemini` interactively once and trust the dir,
-- or set GEMINI_CLI_TRUST_WORKSPACE=true).
function M.build_cmd(bin, prompt, opts)
  local cmd = { bin, "--output-format", "json" }
  if opts.profile and opts.profile.model then
    vim.list_extend(cmd, { "--model", opts.profile.model })
  end
  if opts.session_id and opts.session_id ~= "" then
    vim.list_extend(cmd, { "--session-id", opts.session_id })
  end
  vim.list_extend(cmd, { "--prompt", prompt })
  return cmd
end

-- gemini --output-format json emits a single JSON object:
--   { "session_id": "...", "response": "...", "stats": { "models": { ... } } }
function M.parse_output(stdout)
  -- stdout may have warning lines before the JSON block; find first { to last }
  local raw = vim.trim(stdout)
  local i = raw:find("{")
  local last_j = nil
  if i then
    local pos = i
    while true do
      local found = raw:find("}", pos, true)
      if not found then break end
      last_j = found
      pos = found + 1
    end
  end

  local outer_raw = (i and last_j) and raw:sub(i, last_j) or raw
  local ok, outer = pcall(vim.json.decode, outer_raw)
  if not ok or type(outer) ~= "table" then
    return { code = raw, changes = {}, message = nil, done = true }, nil
  end

  local session_id = outer.session_id

  -- parse response field as novibe JSON
  local response_text = type(outer.response) == "string" and vim.trim(outer.response) or ""
  response_text = response_text:gsub("^```[%w]*\n?", ""):gsub("\n?```%s*$", "")
  response_text = vim.trim(response_text)

  local ok2, response = pcall(vim.json.decode, response_text)
  if not ok2 or type(response) ~= "table" then
    -- try extracting JSON from prose-wrapped response
    local ji = response_text:find("{")
    local jj = nil
    if ji then
      local pos = ji
      while true do
        local found = response_text:find("}", pos, true)
        if not found then break end
        jj = found
        pos = found + 1
      end
    end
    if ji and jj then
      local ok3, r3 = pcall(vim.json.decode, response_text:sub(ji, jj))
      if ok3 and type(r3) == "table" then
        response = r3
      end
    end
    if not response then
      response = { code = response_text, changes = {}, message = nil, done = true }
    end
  end

  -- aggregate token counts across all models used
  local in_tokens, out_tokens = nil, nil
  if outer.stats and outer.stats.models then
    for _, m in pairs(outer.stats.models) do
      if m.tokens then
        in_tokens  = (in_tokens  or 0) + (m.tokens.input      or 0)
        out_tokens = (out_tokens or 0) + (m.tokens.candidates or 0)
      end
    end
  end

  local usage = {
    cost_usd       = nil,  -- gemini free tier reports no cost
    input_tokens   = in_tokens,
    output_tokens  = out_tokens,
    context_window = nil,
    session_id     = session_id,
  }

  return response, usage
end

return M
