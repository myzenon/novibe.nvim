local M = {}

M.name = "opencode"
M.streaming = true

function M.find_bin()
  local found = vim.fn.exepath("opencode")
  if found ~= "" then return found end
  for _, path in ipairs({
    vim.fn.expand("~/.local/bin/opencode"),
    "/usr/local/bin/opencode",
    "/opt/homebrew/bin/opencode",
  }) do
    if vim.fn.filereadable(path) == 1 then return path end
  end
  return nil
end

-- Called once per stdout data chunk. Returns text extracted from text events.
function M.parse_chunk(data)
  local parts = {}
  for _, line in ipairs(vim.split(data, "\n", { plain = true })) do
    if line ~= "" then
      local ok, ev = pcall(vim.json.decode, line)
      if ok and type(ev) == "table" and ev.type == "text"
         and ev.part and type(ev.part.text) == "string" then
        table.insert(parts, ev.part.text)
      end
    end
  end
  return table.concat(parts)
end

-- opts: { profile, session_id }
-- opencode has no equivalent of --bare or --continue (we use --session ID instead).
function M.build_cmd(bin, prompt, opts)
  local cmd = { bin, "run", "--format", "json" }
  if opts.profile and opts.profile.model then
    vim.list_extend(cmd, { "--model", opts.profile.model })
  end
  if opts.profile and opts.profile.effort then
    vim.list_extend(cmd, { "--variant", opts.profile.effort })
  end
  if opts.session_id and opts.session_id ~= "" then
    vim.list_extend(cmd, { "--session", opts.session_id })
  end
  table.insert(cmd, prompt)
  return cmd
end

-- Strip markdown code fences if model wraps JSON in ```json ... ```
local function unwrap_codeblock(text)
  return text:match("^%s*```%s*json%s*\n(.-)\n```%s*$")
      or text:match("^%s*```%s*\n(.-)\n```%s*$")
      or text
end

-- opencode emits newline-delimited JSON events:
--   step_start, text (possibly multiple), step_finish (cost + tokens)
function M.parse_output(stdout)
  local text_parts  = {}
  local session_id  = nil
  local cost        = nil
  local in_tokens   = nil
  local out_tokens  = nil

  for _, line in ipairs(vim.split(stdout, "\n", { plain = true })) do
    if line ~= "" then
      local ok, ev = pcall(vim.json.decode, line)
      if ok and type(ev) == "table" then
        session_id = session_id or ev.sessionID
        if ev.type == "text" and ev.part and type(ev.part.text) == "string" then
          table.insert(text_parts, ev.part.text)
        elseif ev.type == "step_finish" and ev.part then
          if type(ev.part.cost) == "number" then
            cost = (cost or 0) + ev.part.cost
          end
          if type(ev.part.tokens) == "table" then
            if type(ev.part.tokens.input)  == "number" then in_tokens  = ev.part.tokens.input  end
            if type(ev.part.tokens.output) == "number" then out_tokens = ev.part.tokens.output end
          end
        end
      end
    end
  end

  local text = vim.trim(table.concat(text_parts, ""))
  local inner = unwrap_codeblock(text)

  local response
  local ok, parsed = pcall(vim.json.decode, inner)
  if ok and type(parsed) == "table" then
    response = parsed
  else
    response = { code = text, changes = {}, message = nil, done = true }
  end

  local usage = {
    cost_usd       = cost,
    input_tokens   = in_tokens,
    output_tokens  = out_tokens,
    context_window = nil,  -- opencode does not expose context window size
    session_id     = session_id,
  }

  return response, usage
end

return M
