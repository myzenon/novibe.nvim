local M = {}

local state = { buf = nil, win = nil, job = nil, augroup = nil, mode = nil }

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
  state.buf  = nil
  state.win  = nil
  state.mode = nil
end

local CONSULT_HEADER = [[
This is a CONSULT session. Your role is primarily advisory — discuss, explain, review, and answer questions.

FILE WRITING RULES:
- You MAY freely edit these files when the user asks:
    CLAUDE.md, .no_vibe/config.md, .no_vibe/topics/index.md,
    .no_vibe/topics/*/rule.md, .no_vibe/topics/*/doc.md, .no_vibe/topics/*/why.md,
    .no_vibe/act/learned-*.md
- For ALL other files: do NOT modify them, write code to disk, or run shell commands.

KNOWLEDGE BASE — when the user says "snapshot", "save this", or "remember this":
Write what was just discovered to the appropriate topic folder:
  .no_vibe/topics/<area>/doc.md  — project documentation: how features work, call chains, structural knowledge
  .no_vibe/topics/<area>/rule.md — behavioral constraints: how to interact with this area
  .no_vibe/topics/<area>/why.md  — the WHY: architectural decisions and rejected alternatives
  .no_vibe/topics/index.md       — add or update the entry for the area:
                                     ## <Area Name> [<glob>]
                                     <one-line description>
                                     - topics/<area>/

In each file you write, include a last-verified comment with the current commit hash:
  <!-- last-verified: COMMIT_HASH -->

This lets the system warn the user if that area of the codebase has changed since the knowledge was written.

EXISTING KNOWLEDGE — sections below marked ⚠ STALE mean that area has new commits since the knowledge was written. Treat stale sections as hints only — verify against the actual code before relying on them.

Project conventions and personal config are injected below.]]

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
  - ALWAYS ask the user for explicit confirmation before running git commit or git push — even if
    the user already said "commit" or "push" earlier. Confirm the exact command first, then wait.

KNOWLEDGE BASE — when the user says "snapshot", "save this", or "remember this":
Write discoveries to the appropriate topic folder with a last-verified comment:
  .no_vibe/topics/<area>/rule.md — behavioral constraints: how to interact with this area
  .no_vibe/topics/<area>/doc.md  — project documentation: features, call chains, structural knowledge
  .no_vibe/topics/<area>/why.md  — the WHY: architectural decisions, rejected alternatives
  .no_vibe/topics/index.md       — add or update the area entry:
                                     ## <Area Name> [<glob>]
                                     <one-line description>
                                     - topics/<area>/

In each file you write, include a last-verified comment with the current commit hash:
  <!-- last-verified: COMMIT_HASH -->

EXISTING KNOWLEDGE — sections marked ⚠ STALE have new commits since they were written. Verify before relying on them.

KNOWLEDGE BASE (KB) — when the user says "KB", "the KB", or "our KB", they mean:
  .no_vibe/topics/ and .no_vibe/config.md.
  "Look at KB" = read those files. "Update KB" = write to the right topic folder.

COMMANDS — recognize these phrases at any time:
  "restore context" / "reload context" / "refresh context"
               Re-inject project context after /compact or /clear. Run:
                 nvim --server "$NVIM" --remote-expr "luaeval('require(\"novibe.consult\").get_seed()')"
               Treat the output as your refreshed context.
  "show me X" / "open X" / "navigate to X"
               Open a file in a new vsplit (does not replace this window). Run:
                 nvim --server "$NVIM" --remote-expr "execute('vsplit <filepath>')"

Project conventions and personal config are injected below.]]

-- Build the shared file/selection/conventions context block.
-- mode: "act" (default) or "agent" — controls which config.md sections are loaded.
local function build_context(line1, line2, has_range, mode)
  local prev_buf = vim.api.nvim_get_current_buf()
  local win      = vim.api.nvim_get_current_win()
  local filename = vim.api.nvim_buf_get_name(prev_buf)
  local cursor   = vim.api.nvim_win_get_cursor(win)

  local selection
  if has_range and line1 and line2 then
    local lines = vim.api.nvim_buf_get_lines(prev_buf, line1 - 1, line2, false)
    selection = table.concat(lines, "\n")
  end

  local no_vibe_txt = require("novibe.no_vibe").load(filename, mode or "act")
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
  return CONSULT_HEADER .. build_context(line1, line2, has_range, "agent")
end

local CLAUDE_PLAN_MODE = [[

PLAN MODE — you have access to EnterPlanMode and ExitPlanMode tools.
For any multi-step implementation task, use them exactly as Claude Code does:
  1. Call EnterPlanMode before planning — explore, then write your plan.
  2. Call ExitPlanMode to present the plan and wait for user approval.
  3. Only implement after the user approves.
Do this autonomously — do not wait for the user to ask you to plan.]]

local NON_CLAUDE_SEED_PREAMBLE = [[
IMPORTANT: This message is your system prompt and standing instructions for this
entire session. Before acting on any user request, re-read this message and
complete all startup steps described here.

]]

local CODEX_AGENT_HEADER = [[
This is an AGENT session. You have full read/write access to the entire project.

Before making changes: read relevant files, produce a brief numbered plan, and
wait for confirmation. Follow project conventions for plan format and detail level.

SAFETY:
  - Do not run destructive commands (rm -rf, git reset --hard, etc.) without explicit permission.
  - Do not commit or push unless asked. Always confirm the exact command before running
    git commit or git push.

KNOWLEDGE BASE — when the user says "snapshot", "save this", or "remember this":
Write discoveries to the appropriate topic folder with a last-verified comment:
  .no_vibe/topics/<area>/rule.md — behavioral constraints: how to interact with this area
  .no_vibe/topics/<area>/doc.md  — project documentation: features, call chains, structural knowledge
  .no_vibe/topics/<area>/why.md  — the WHY: architectural decisions, rejected alternatives
  .no_vibe/topics/index.md       — add or update the area entry:
                                     ## <Area Name> [<glob>]
                                     <one-line description>
                                     - topics/<area>/

In each file you write, include a last-verified comment with the current commit hash:
  <!-- last-verified: COMMIT_HASH -->

EXISTING KNOWLEDGE — sections marked ⚠ STALE have new commits since they were written. Verify before relying on them.

KNOWLEDGE BASE (KB) — when the user says "KB", "the KB", or "our KB", they mean:
  .no_vibe/topics/ and .no_vibe/config.md.
  "Look at KB" = read those files. "Update KB" = write to the right topic folder.

COMMANDS — recognize these phrases at any time:
  "restore context" / "reload context" / "refresh context"
               Re-inject project context after /compact or /clear. Run:
                 nvim --server "$NVIM" --remote-expr "luaeval('require(\"novibe.consult\").get_seed()')"
               Treat the output as your refreshed context.
  "show me X" / "open X" / "navigate to X"
               Open a file in a new vsplit (does not replace this window). Run:
                 nvim --server "$NVIM" --remote-expr "execute('vsplit <filepath>')"

Project conventions and personal config are injected below.]]

-- Build the agent seed: full file access + plan-then-execute enforced.
-- Task management behavior (including which files to read at session start) is
-- defined entirely in the user's .no_vibe/config.md ## Agent section.
local function build_agent_seed(line1, line2, has_range)
  local config  = require("novibe.config")
  local profile = config.options.active_agent_profile or config.options.active_profile
  local provider_name = (profile and profile.provider) or config.options.provider or "claude"
  local header
  if provider_name == "claude" then
    header = AGENT_HEADER .. CLAUDE_PLAN_MODE
  elseif provider_name == "codex" then
    header = NON_CLAUDE_SEED_PREAMBLE .. CODEX_AGENT_HEADER
  else
    header = NON_CLAUDE_SEED_PREAMBLE .. AGENT_HEADER
  end
  return header .. "\n" .. build_context(line1, line2, has_range, "agent")
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
  elseif provider_name == "antigravity" then
    cmd = { bin }
    if profile and profile.model then vim.list_extend(cmd, { "--model", profile.model }) end
    vim.list_extend(cmd, { "--prompt-interactive", seed })
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
  state.mode   = "consult"

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
  local profile   = config.options.active_agent_profile or config.options.active_profile
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
  elseif provider_name == "antigravity" then
    cmd = { bin }
    if profile and profile.model then vim.list_extend(cmd, { "--model", profile.model }) end
    vim.list_extend(cmd, { "--prompt-interactive", seed })
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

  -- Agent opens in the current window (replaces the buffer) rather than a split.
  local term_win = vim.api.nvim_get_current_win()
  local term_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(term_win, term_buf)
  local job = vim.fn.termopen(cmd, {
    on_exit = function()
      state.job = nil
      -- Delete the terminal buffer; window stays open showing the previous buffer.
      vim.schedule(function()
        if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
          pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
        end
        state.buf = nil
        state.win = nil
      end)
    end,
  })

  state.buf  = vim.api.nvim_get_current_buf()
  state.win  = nil  -- no split to close; window persists after buffer is deleted
  state.job  = job
  state.mode = "agent"

  vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", { buffer = state.buf, desc = "novibe: exit terminal mode" })

  vim.keymap.set("n", "q", function() vim.schedule(cleanup) end,
    { buffer = state.buf, nowait = true, desc = "novibe: close agent" })

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
      -- Don't close the window; agent ran in the current window, not a split.
      state.buf = nil
      state.win = nil
    end,
  })

  if provider_name == "opencode" then
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

function M.is_agent_active()
  return state.job ~= nil and state.mode == "agent"
end

function M.send_question(text, immediate)
  if not state.job then
    vim.notify("novibe: no active consult session", vim.log.levels.WARN)
    return
  end
  local config    = require("novibe.config")
  local providers = require("novibe.providers")
  local profile   = config.options.active_agent_profile or config.options.active_profile
  local provider  = providers.get(profile and profile.provider)
  -- opencode needs longer — its seed is deferred 3 s after startup
  local delay = immediate and 100 or (provider.name == "opencode" and 5000 or 2000)
  vim.defer_fn(function()
    if not state.job then return end
    local body = text:gsub("[\r\n]+$", "")
    pcall(vim.api.nvim_chan_send, state.job, "\x1b[200~" .. body .. "\x1b[201~\r")
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

function M.send_agent_prompt(line1, line2, has_range)
  if not state.job or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    vim.notify("novibe: no active agent session — run :NovibeAgent first", vim.log.levels.WARN)
    return
  end
  if state.mode ~= "agent" then
    vim.notify("novibe: active session is not an agent session", vim.log.levels.WARN)
    return
  end
  if vim.api.nvim_get_current_buf() == state.buf then
    vim.notify("novibe: run :NovibeAgentPrompt from the source buffer, not the agent terminal", vim.log.levels.WARN)
    return
  end
  local seed = build_agent_seed(line1, line2, has_range)
  local body = seed:gsub("[\r\n]+$", "")
  local ok, err = pcall(vim.api.nvim_chan_send, state.job, "\x1b[200~" .. body .. "\x1b[201~\r")
  if not ok then
    vim.notify("novibe: chan_send failed — " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.get_seed()
  return build_agent_seed(nil, nil, false)
end

return M
