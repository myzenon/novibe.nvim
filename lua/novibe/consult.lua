local M = {}

local state = { buf = nil, win = nil, job = nil, augroup = nil }

local function cleanup()
  -- Remove augroup first so BufUnload doesn't fire during our own teardown
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  if state.job then
    pcall(vim.fn.jobstop, state.job)
    state.job = nil
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf = nil
  state.win = nil
end

local CONSULT_HEADER = [[
This is a CONSULT session. Your role is primarily advisory — discuss, explain, review, and answer questions.

FILE WRITING RULES:
- You MAY freely edit these files when the user asks:
    CLAUDE.md, .no_vibe/convention-*.md, .no_vibe/learned-*.md
    .no_vibe/map-*.md, .no_vibe/rule-*.md, .no_vibe/decision-*.md
- For ALL other files: do NOT modify them, write code to disk, or run shell commands.

KNOWLEDGE BASE — when the user says "snapshot", "save this", or "remember this":
Write what was just discovered to the appropriate .no_vibe/ file:
  map-<area>.md     — dependency graph: who depends on what, call chains, inheritance
  rule-<area>.md    — behavioral constraints: how to interact with each area (e.g. "always use Class X as proxy")
  decision-<area>.md — the WHY: architectural decisions and rejected alternatives

Each file uses glob section headers so only relevant sections load per file:
  ## always              → always injected
  ## src/db/**           → injected when working in src/db/
  ## src/routes/routeA/** → injected when working in that route

In each section you write, include a last-verified comment with the current commit hash:
  <!-- last-verified: COMMIT_HASH -->

This lets the system warn the user if that area of the codebase has changed since the knowledge was written.

EXISTING KNOWLEDGE — sections below marked ⚠ STALE mean that area has new commits since the knowledge was written. Treat stale sections as hints only — verify against the actual code before relying on them.

Project conventions (.no_vibe/convention-*.md and .no_vibe/learned-*.md) use the same section format and are also injected below.]]

local AGENT_HEADER = [[
This is an AGENT session. You have full read/write access to the entire project.

MANDATORY TWO-STEP WORKFLOW — never skip or merge these steps:

STEP 1 — PLAN (always first, no exceptions):
  - Read the relevant files before writing anything.
  - Produce a numbered plan listing every change you will make:
      • File path
      • Exact code block you will find (verbatim)
      • What you will replace it with and why
  - Ask clarifying questions BEFORE producing the plan if anything is unclear.
  - End with: "Plan complete. Confirm to execute." then STOP and wait.

STEP 2 — EXECUTE (only after the user explicitly confirms):
  - Implement each step exactly as described in the plan — no additions, no omissions.
  - If you discover something unexpected mid-execution, STOP and explain before continuing.
  - Do not run destructive commands (rm -rf, git reset --hard, etc.) without explicit permission.
  - Do not commit or push unless asked.

KNOWLEDGE BASE — when the user says "snapshot", "save this", or "remember this":
Write discoveries to the appropriate .no_vibe/ file with a last-verified comment:
  map-<area>.md      — dependency graph: call chains, inheritance, who owns what
  rule-<area>.md     — behavioral constraints: how to interact with each area
  decision-<area>.md — the WHY: architectural decisions and rejected alternatives

EXISTING KNOWLEDGE — sections marked ⚠ STALE have new commits since they were written. Verify before relying on them.

Project conventions are injected below.]]

-- Build the shared file/selection/conventions context block.
local function build_context(line1, line2, has_range)
  local prev_buf = vim.api.nvim_get_current_buf()
  local win      = vim.api.nvim_get_current_win()
  local filename = vim.api.nvim_buf_get_name(prev_buf)
  local cursor   = vim.api.nvim_win_get_cursor(win)

  local selection
  if has_range and line1 and line2 then
    local lines = vim.api.nvim_buf_get_lines(prev_buf, line1 - 1, line2, false)
    selection = table.concat(lines, "\n")
  end

  local no_vibe_txt = require("novibe.no_vibe").load(filename)
  local commit = vim.trim(vim.fn.system("git rev-parse HEAD 2>/dev/null"))
  if not commit:match("^[%x]+$") then commit = nil end

  local parts = {}

  if filename ~= "" then
    table.insert(parts, "\nCurrent file: " .. vim.fn.fnamemodify(filename, ":.") .. " (line " .. cursor[1] .. ")")
  end
  if commit then
    table.insert(parts, "Current commit: " .. commit)
  end

  local focus_line = (has_range and line1) or cursor[1]
  local enclosing = require("novibe.context").enclosing(prev_buf, focus_line, 1)
  if enclosing then
    table.insert(parts, "\n" .. enclosing)
  end

  if selection and selection ~= "" then
    table.insert(parts, "\nSelected code:\n```\n" .. selection .. "\n```")
  end

  local diag_txt = require("novibe.diag").format(
    prev_buf,
    has_range and line1 or nil,
    has_range and line2 or nil
  )
  if diag_txt then
    table.insert(parts, "\n" .. diag_txt)
  end

  if no_vibe_txt then
    table.insert(parts, "\nProject conventions (sections matching this file):\n" .. no_vibe_txt)
  else
    table.insert(parts, "\nNo project conventions found for this file.")
  end

  return table.concat(parts, "\n")
end

-- Build the consult seed text from the current buffer/selection/conventions.
-- Used by both :NovibeConsult (injected via CLI flag where supported) and
-- :NovibeConsultPrompt (chansent into an already-running opencode terminal).
local function build_seed(line1, line2, has_range)
  return CONSULT_HEADER .. build_context(line1, line2, has_range)
end

-- Build the agent seed: full file access + plan-then-execute enforced.
local function build_agent_seed(line1, line2, has_range)
  return AGENT_HEADER .. build_context(line1, line2, has_range)
end

-- line1/line2/has_range: passed from command range (:'<,'>NovibeConsult)
function M.open(line1, line2, has_range)
  cleanup()

  local config      = require("novibe.config")
  local providers   = require("novibe.providers")
  local profile     = config.options.active_consult_profile or config.options.active_profile
  local provider    = providers.get(profile and profile.provider)
  local bin         = provider.find_bin()

  if not bin then
    vim.notify("novibe: " .. provider.name .. " binary not found", vim.log.levels.ERROR)
    return
  end

  local seed = build_seed(line1, line2, has_range)

  local provider_name = provider.name

  local cmd
  if provider_name == "opencode" then
    -- opencode TUI has no flag for pre-seeding context; user types it manually
    cmd = { bin }
  elseif provider_name == "gemini" then
    -- --prompt-interactive seeds context then stays in interactive TUI mode
    cmd = { bin }
    if profile and profile.model then vim.list_extend(cmd, { "--model", profile.model }) end
    vim.list_extend(cmd, { "--prompt-interactive", seed })
  elseif provider_name == "antigravity" then
    -- agy --prompt-interactive seeds context then stays in interactive TUI mode (no --model flag)
    cmd = { bin, "--prompt-interactive", seed }
  elseif provider_name == "codex" then
    -- codex TUI accepts an optional initial prompt as a positional argument
    cmd = { bin }
    if profile and profile.model then vim.list_extend(cmd, { "-m", profile.model }) end
    table.insert(cmd, seed)
  else
    -- claude: inject context via system prompt
    cmd = { bin }
    if profile and profile.model  then vim.list_extend(cmd, { "--model",  profile.model  }) end
    if profile and profile.effort then vim.list_extend(cmd, { "--effort", profile.effort }) end
    vim.list_extend(cmd, { "--append-system-prompt", seed })
  end

  local prev_win = vim.api.nvim_get_current_win()

  -- Open terminal in a horizontal split below; close split on exit
  local function restore()
    vim.schedule(function()
      if state.win and vim.api.nvim_win_is_valid(state.win) then
        vim.api.nvim_win_close(state.win, true)
      end
      if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
      end
      state.buf = nil
      state.win = nil
    end)
  end

  vim.cmd("belowright vsplit")
  local term_win = vim.api.nvim_get_current_win()
  -- Replace the duplicated buffer with a fresh one so the original window is unaffected
  local term_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(term_win, term_buf)
  local job = vim.fn.termopen(cmd, {
    on_exit = function()
      state.job = nil
      restore()
    end,
  })

  state.buf    = vim.api.nvim_get_current_buf()
  state.win    = term_win
  state.job    = job

  -- <Esc><Esc> exits terminal mode without sending ESC to the TUI process
  vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", { buffer = state.buf, desc = "novibe: exit terminal mode" })

  -- q in normal mode closes the consult window and stops the process
  vim.keymap.set("n", "q", function() vim.schedule(cleanup) end,
    { buffer = state.buf, nowait = true, desc = "novibe: close consult" })

  -- Override TmuxNavigator terminal-mode mappings so they exit terminal mode
  -- first and let the normal-mode mapping handle navigation, instead of leaking
  -- command text ("TmuxNavigateLeft" etc.) into the terminal process.
  for _, key in ipairs({ "<C-h>", "<C-j>", "<C-k>", "<C-l>" }) do
    vim.keymap.set("t", key, "<C-\\><C-n>" .. key, { buffer = state.buf, nowait = true })
  end

  local ag = vim.api.nvim_create_augroup("NovibeConsult", { clear = true })
  state.augroup = ag
  vim.api.nvim_create_autocmd("BufUnload", {
    group    = ag,
    buffer   = state.buf,
    once     = true,
    callback = function()
      state.augroup = nil
      if state.job then
        pcall(vim.fn.jobstop, state.job)
        state.job = nil
      end
      if state.win and vim.api.nvim_win_is_valid(state.win) then
        pcall(vim.api.nvim_win_close, state.win, true)
      end
      state.buf = nil
      state.win = nil
    end,
  })

  if provider_name == "opencode" then
    -- Return focus to source window; auto-send prompt after opencode has had time to start
    if vim.api.nvim_win_is_valid(prev_win) then
      vim.api.nvim_set_current_win(prev_win)
    end
    vim.defer_fn(function()
      vim.notify("novibe: auto-sending consult prompt to opencode…", vim.log.levels.INFO)
      M.send_prompt(line1, line2, has_range)
    end, 3000)
  else
    vim.cmd("startinsert")
  end
end

-- Open an AGENT session: full project access, plan-then-execute enforced.
-- Same TUI machinery as M.open but with the agent seed prompt.
function M.open_agent(line1, line2, has_range)
  cleanup()

  local config    = require("novibe.config")
  local providers = require("novibe.providers")
  local profile   = config.options.active_consult_profile or config.options.active_profile
  local provider  = providers.get(profile and profile.provider)
  local bin       = provider.find_bin()

  if not bin then
    vim.notify("novibe: " .. provider.name .. " binary not found", vim.log.levels.ERROR)
    return
  end

  local seed          = build_agent_seed(line1, line2, has_range)
  local provider_name = provider.name

  local cmd
  if provider_name == "opencode" then
    cmd = { bin }
  elseif provider_name == "gemini" then
    cmd = { bin }
    if profile and profile.model then vim.list_extend(cmd, { "--model", profile.model }) end
    vim.list_extend(cmd, { "--prompt-interactive", seed })
  elseif provider_name == "antigravity" then
    cmd = { bin, "--prompt-interactive", seed }
  elseif provider_name == "codex" then
    cmd = { bin }
    if profile and profile.model then vim.list_extend(cmd, { "-m", profile.model }) end
    table.insert(cmd, seed)
  else
    cmd = { bin }
    if profile and profile.model  then vim.list_extend(cmd, { "--model",  profile.model  }) end
    if profile and profile.effort then vim.list_extend(cmd, { "--effort", profile.effort }) end
    vim.list_extend(cmd, { "--append-system-prompt", seed })
  end

  local prev_win = vim.api.nvim_get_current_win()

  local function restore()
    vim.schedule(function()
      if state.win and vim.api.nvim_win_is_valid(state.win) then
        vim.api.nvim_win_close(state.win, true)
      end
      if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
      end
      state.buf = nil
      state.win = nil
    end)
  end

  vim.cmd("belowright vsplit")
  local term_win = vim.api.nvim_get_current_win()
  local term_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(term_win, term_buf)
  local job = vim.fn.termopen(cmd, {
    on_exit = function()
      state.job = nil
      restore()
    end,
  })

  state.buf = vim.api.nvim_get_current_buf()
  state.win = term_win
  state.job = job

  vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", { buffer = state.buf, desc = "novibe: exit terminal mode" })

  vim.keymap.set("n", "q", function() vim.schedule(cleanup) end,
    { buffer = state.buf, nowait = true, desc = "novibe: close consult" })

  for _, key in ipairs({ "<C-h>", "<C-j>", "<C-k>", "<C-l>" }) do
    vim.keymap.set("t", key, "<C-\\><C-n>" .. key, { buffer = state.buf, nowait = true })
  end

  local ag = vim.api.nvim_create_augroup("NovibeConsult", { clear = true })
  state.augroup = ag
  vim.api.nvim_create_autocmd("BufUnload", {
    group    = ag,
    buffer   = state.buf,
    once     = true,
    callback = function()
      state.augroup = nil
      if state.job then
        pcall(vim.fn.jobstop, state.job)
        state.job = nil
      end
      if state.win and vim.api.nvim_win_is_valid(state.win) then
        pcall(vim.api.nvim_win_close, state.win, true)
      end
      state.buf = nil
      state.win = nil
    end,
  })

  if provider_name == "opencode" then
    if vim.api.nvim_win_is_valid(prev_win) then
      vim.api.nvim_set_current_win(prev_win)
    end
    vim.defer_fn(function()
      vim.notify("novibe: auto-sending agent prompt to opencode…", vim.log.levels.INFO)
      M.send_prompt(line1, line2, has_range)
    end, 3000)
  else
    vim.cmd("startinsert")
  end
end

-- Send a plain question into the active consult terminal after a short delay.
-- Used by act2's #ask flow: consult.open seeds context, send_question fires the question.
function M.is_active()
  return state.job ~= nil
end

function M.send_question(text, immediate)
  if not state.job then
    vim.notify("novibe: no active consult session", vim.log.levels.WARN)
    return
  end
  local config    = require("novibe.config")
  local providers = require("novibe.providers")
  local profile   = config.options.active_consult_profile or config.options.active_profile
  local provider  = providers.get(profile and profile.provider)
  -- opencode needs longer — its seed is deferred 3 s after startup
  local delay = immediate and 100 or (provider.name == "opencode" and 5000 or 2000)
  vim.defer_fn(function()
    if not state.job then return end
    pcall(vim.api.nvim_chan_send, state.job, text:gsub("[\r\n]+$", "") .. "\r")
  end, delay)
end

-- Build the seed from the current buffer/selection and chansend it into the
-- active consult terminal (intended for opencode/codex, which have no CLI flag
-- for pre-seeding context). User presses Enter manually to submit.
function M.send_prompt(line1, line2, has_range)
  if not state.job or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    vim.notify("novibe: no active consult session — run :NovibeConsult first", vim.log.levels.WARN)
    return
  end
  if vim.api.nvim_get_current_buf() == state.buf then
    vim.notify("novibe: run :NovibeConsultPrompt from the source buffer, not the consult terminal", vim.log.levels.WARN)
    return
  end
  local seed = build_seed(line1, line2, has_range)
  -- Strip trailing newlines then add exactly one so the TUI auto-submits.
  seed = seed:gsub("[\r\n]+$", "") .. "\r"
  local ok, err = pcall(vim.api.nvim_chan_send, state.job, seed)
  if ok then
    vim.notify("novibe: prompt sent to consult — press Enter in the terminal to submit", vim.log.levels.INFO)
  else
    vim.notify("novibe: chan_send failed — " .. tostring(err), vim.log.levels.ERROR)
  end
end

return M
