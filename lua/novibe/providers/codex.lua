local M = {}

M.name      = "codex"
M.streaming = false

function M.find_bin()
  local found = vim.fn.exepath("codex")
  if found ~= "" then return found end
  for _, path in ipairs({
    vim.fn.expand("~/.local/bin/codex"),
    "/usr/local/bin/codex",
    "/opt/homebrew/bin/codex",
  }) do
    if vim.fn.filereadable(path) == 1 then return path end
  end
  return nil
end

-- Non-streaming: parse_chunk is never called, but satisfy the interface.
function M.parse_chunk(_) return "" end

-- Encode s as a TOML double-quoted string value (without the outer quotes).
local function toml_escape(s)
  return s
    :gsub("\\", "\\\\")
    :gsub('"',  '\\"')
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t")
end

-- opts: { profile, session_id, use_continue }
-- codex has no --bare or streaming; session continuity uses explicit thread_id.
function M.build_cmd(bin, prompt, opts)
  local sys = require("novibe.config").options.system_prompt or ""
  -- Suppress codex's agentic shell-command loop — we only need JSON text output.
  sys = sys .. "\n\nIMPORTANT: Do not run any shell commands. Respond only with the JSON object."
  local instructions_arg = "-c"
  local instructions_val = 'instructions="' .. toml_escape(sys) .. '"'

  local is_resume = opts.session_id and opts.session_id ~= ""

  local cmd
  if is_resume then
    -- Resume the exact previous thread by UUID for precise continuity.
    cmd = { bin, "exec", "resume", opts.session_id, "--json", instructions_arg, instructions_val }
  else
    cmd = { bin, "exec", "--json", "--sandbox", "read-only", instructions_arg, instructions_val }
  end

  if opts.profile and opts.profile.model then
    vim.list_extend(cmd, { "-m", opts.profile.model })
  end

  table.insert(cmd, prompt)
  return cmd
end

-- Unwrap markdown code fences and parse JSON; fall back to raw text.
local function parse_text(text)
  local s = text:gsub("^```[%w]*\n?", ""):gsub("\n?```%s*$", "")
  s = vim.trim(s)
  local ok, parsed = pcall(vim.json.decode, s)
  if ok and type(parsed) == "table" then return parsed end
  -- try substring between first { and last }
  local i = s:find("{")
  local j = nil
  local pos = 1
  while true do
    local found = s:find("}", pos, true)
    if not found then break end
    j = found; pos = found + 1
  end
  if i and j then
    local ok2, r = pcall(vim.json.decode, s:sub(i, j))
    if ok2 and type(r) == "table" then return r end
  end
  return { code = text, changes = {}, message = nil, done = true }
end

-- codex --json event stream:
--   {"type":"thread.started","thread_id":"..."}
--   {"type":"turn.started"}
--   {"type":"item.started","item":{...command...}}          -- skip
--   {"type":"item.completed","item":{...command...}}        -- skip
--   {"type":"item.completed","item":{"type":"agent_message","text":"..."}}
--   {"type":"turn.completed","usage":{...}}
function M.parse_output(stdout)
  local thread_id  = nil
  local text       = nil
  local in_tokens  = nil
  local out_tokens = nil

  for _, line in ipairs(vim.split(stdout, "\n", { plain = true })) do
    if line ~= "" then
      local ok, ev = pcall(vim.json.decode, line)
      if ok and type(ev) == "table" then
        if ev.type == "thread.started" then
          thread_id = ev.thread_id
        elseif ev.type == "item.completed"
            and type(ev.item) == "table"
            and ev.item.type == "agent_message"
            and type(ev.item.text) == "string" then
          text = ev.item.text
        elseif ev.type == "turn.completed" and type(ev.usage) == "table" then
          in_tokens  = ev.usage.input_tokens
          out_tokens = ev.usage.output_tokens
        end
      end
    end
  end

  local response = text and parse_text(text)
    or { code = "", changes = {}, message = "codex returned no response", done = true }

  return response, {
    cost_usd       = nil,
    input_tokens   = in_tokens,
    output_tokens  = out_tokens,
    context_window = nil,
    session_id     = thread_id,
  }
end

return M
