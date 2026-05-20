local M = {}

M.name      = "antigravity"
M.streaming = false

-- The Antigravity desktop editor (a VS Code fork) also ships an `agy` binary
-- on both macOS and Linux — it's a shell wrapper that launches Electron, so
-- invoking it would open a GUI window. The actual Antigravity CLI is a
-- compiled Go binary (Mach-O / ELF / PE). Detect by reading the first two
-- bytes: shell scripts start with "#!", binaries don't.
local function is_cli(path)
  local f = io.open(path, "rb")
  if not f then return false end
  local head = f:read(2) or ""
  f:close()
  return head ~= "#!"
end

function M.find_bin()
  -- Gather all candidates: canonical install paths plus every `agy` in PATH.
  local seen, candidates = {}, {}
  local function add(p)
    if p and p ~= "" and not seen[p] then
      seen[p] = true
      table.insert(candidates, p)
    end
  end
  add(vim.fn.expand("~/.local/bin/agy"))
  add("/usr/local/bin/agy")                       -- Intel macOS Homebrew / manual installs
  add("/opt/homebrew/bin/agy")                    -- Apple Silicon Homebrew
  add("/home/linuxbrew/.linuxbrew/bin/agy")       -- Linuxbrew
  add("/usr/bin/agy")                             -- Linux distro packages
  for _, p in ipairs(vim.fn.systemlist("command -v -a agy 2>/dev/null")) do
    add(p)
  end

  for _, path in ipairs(candidates) do
    if vim.fn.filereadable(path) == 1 and is_cli(path) then
      return path
    end
  end
  return nil
end

-- Non-streaming: parse_chunk is never called, but satisfies the interface.
function M.parse_chunk(_) return "" end

-- opts: { session_id, stream }
-- agy has no --model, --effort, --bare, or system-prompt flags.
-- System prompt is prepended to the user prompt since there is no injection flag.
-- Session continuity uses --continue (resumes most recent conversation for cwd).
function M.build_cmd(bin, prompt, opts)
  local sys = require("novibe.config").options.system_prompt or ""
  local full_prompt = sys ~= ""
    and ("<instructions>\n" .. sys .. "\n</instructions>\n\n" .. prompt)
    or prompt

  local cmd = { bin }
  if opts.session_id and opts.session_id ~= "" then
    table.insert(cmd, "--continue")
  end
  vim.list_extend(cmd, { "--print", full_prompt })
  return cmd
end

-- Unwrap markdown code fences and parse JSON; fall back to raw text.
local function parse_text(text)
  local s = text:gsub("^```[%w]*\n?", ""):gsub("\n?```%s*$", "")
  s = vim.trim(s)
  local ok, parsed = pcall(vim.json.decode, s)
  if ok and type(parsed) == "table" then return parsed end
  local i, j, pos = s:find("{"), nil, 1
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

-- stdout is the raw AI response text (no JSON wrapper).
-- Returns a sentinel session_id so subsequent calls use --continue.
function M.parse_output(stdout)
  local text = vim.trim(stdout)
  local response = text ~= "" and parse_text(text)
    or { code = "", changes = {}, message = "antigravity returned no response", done = true }
  return response, {
    cost_usd       = nil,
    input_tokens   = nil,
    output_tokens  = nil,
    context_window = nil,
    session_id     = "__continue__",
  }
end

return M
