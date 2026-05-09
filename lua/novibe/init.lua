local M = {}
local config  = require("novibe.config")
local input   = require("novibe.input")
local chat    = require("novibe.chat")
local apply   = require("novibe.apply")
local glob    = require("novibe.glob")
local no_vibe = require("novibe.no_vibe")
local learn   = require("novibe.learn")
local util    = require("novibe.util")

M._last_fill      = nil    -- { original, bufnr, start_line }
M._session_count  = 0      -- fills since last reset
M._skip_continue  = false  -- set true by :NovibeReset; consumed on next fill
M._session_cost   = 0.0    -- cumulative USD this Neovim session
M._last_usage     = nil    -- usage table from most recent fill

local SESSION_WARN_AFTER = 10

local ns = vim.api.nvim_create_namespace("novibe")
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local loading_messages = {
  "cooking…",
  "typing so you don't have to…",
  "filling the blanks…",
  "connecting the dots…",
  "following your lead…",
  "reading the comments…",
  "doing the boring part…",
  "translating intent…",
  "implementing your vision…",
  "turning spec into code…",
  "no vibes, just work…",
  "respecting the architecture…",
  "staying in scope…",
  "asking claude nicely…",
  "not redesigning anything…",
}

local function random_loading_msg()
  return loading_messages[math.random(#loading_messages)]
end


local function find_claude()
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
M._find_claude = find_claude

local function start_spinner(bufnr, start_line, end_line)
  local frame = 1
  local msg   = random_loading_msg()
  local virt  = { { { spinner_frames[frame] .. "  " .. msg, "Comment" } } }

  local top_id = vim.api.nvim_buf_set_extmark(bufnr, ns, start_line - 1, 0, {
    virt_lines = virt, virt_lines_above = true,
  })
  local bot_id = vim.api.nvim_buf_set_extmark(bufnr, ns, end_line - 1, 0, {
    virt_lines = virt,
  })

  local timer = vim.uv.new_timer()
  timer:start(80, 80, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      timer:stop(); timer:close(); return
    end
    frame = (frame % #spinner_frames) + 1
    local v = { { { spinner_frames[frame] .. "  " .. msg, "Comment" } } }
    vim.api.nvim_buf_set_extmark(bufnr, ns, start_line - 1, 0,
      { id = top_id, virt_lines = v, virt_lines_above = true })
    vim.api.nvim_buf_set_extmark(bufnr, ns, end_line - 1, 0,
      { id = bot_id, virt_lines = v })
  end))

  return function()
    timer:stop(); timer:close()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_del_extmark(bufnr, ns, top_id)
      vim.api.nvim_buf_del_extmark(bufnr, ns, bot_id)
    end
  end
end

function M.statusline()
  if not M._last_usage then return "" end
  local u = M._last_usage
  local parts = {}
  if u.cost_usd then
    table.insert(parts, string.format("$%.4f", u.cost_usd))
  end
  if u.input_tokens and u.context_window and u.context_window > 0 then
    local pct = math.floor(u.input_tokens / u.context_window * 100)
    table.insert(parts, string.format("ctx %d%%", pct))
  end
  return #parts > 0 and (" " .. table.concat(parts, " · ")) or ""
end

function M.setup(opts)
  config.setup(opts)
  if config.options.keymap then
    vim.keymap.set("v", config.options.keymap, function()
      M.fill()
    end, { desc = "novibe: fill implementation", silent = true })
  end
end

function M.fill(line1, line2)
  local claude_bin = find_claude()
  if not claude_bin then
    vim.notify("novibe: claude binary not found", vim.log.levels.ERROR)
    return
  end

  -- only exit visual mode (to flush '<,'> marks) when called from a keymap
  -- with no explicit range; when line1/line2 are provided the marks aren't needed
  -- and a stray Esc in the typeahead would fire inside the input float
  if line1 == nil or line2 == nil then
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false
    )
  end

  local bufnr      = vim.api.nvim_get_current_buf()
  local start_line = line1 or vim.fn.getpos("'<")[2]
  local end_line   = line2 or vim.fn.getpos("'>")[2]
  local total      = vim.api.nvim_buf_line_count(bufnr)

  local lines     = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local selection = table.concat(lines, "\n")

  local ctx_before = vim.api.nvim_buf_get_lines(bufnr, math.max(0, start_line - 11), start_line - 1, false)
  local ctx_after  = vim.api.nvim_buf_get_lines(bufnr, end_line, math.min(total, end_line + 10), false)

  local input_stats
  if M._last_usage then
    local u = M._last_usage
    local parts = {}
    if u.cost_usd then table.insert(parts, string.format("$%.4f", u.cost_usd)) end
    if u.input_tokens and u.context_window and u.context_window > 0 then
      table.insert(parts, string.format("ctx %d%%", math.floor(u.input_tokens / u.context_window * 100)))
    end
    if #parts > 0 then input_stats = table.concat(parts, " · ") end
  end

  input.open(function(user_prompt)
    if user_prompt == nil then return end

    -- #teach mode: diff current selection against last fill
    if vim.startswith(user_prompt, "#teach") then
      if not M._last_fill then
        vim.notify("novibe: no recent fill to teach from", vim.log.levels.WARN)
        return
      end
      if M._last_fill.bufnr ~= bufnr then
        vim.notify("novibe: last fill was in a different buffer — switch to it to use #teach", vim.log.levels.WARN)
        return
      end
      local reason  = vim.trim(user_prompt:sub(7))
      local current = table.concat(
        vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false), "\n"
      )
      learn.teach(
        M._last_fill.original,
        current,
        reason,
        vim.api.nvim_buf_get_name(bufnr),
        claude_bin,
        config.options.learn and config.options.learn.auto_extract_after,
        config.options.active_profile
      )
      return
    end

    local filename    = vim.api.nvim_buf_get_name(bufnr)
    local no_vibe_txt = no_vibe.load(filename)
    local parts = {
      config.options.system_prompt,
      no_vibe_txt and ("\nProject conventions:\n" .. no_vibe_txt) or "",
      "",
    }
    if #ctx_before > 0 then
      table.insert(parts, "Context before selection (DO NOT reproduce this):")
      table.insert(parts, table.concat(ctx_before, "\n"))
      table.insert(parts, "")
    end
    table.insert(parts, "Selection to modify (return in the 'code' field ONLY):")
    table.insert(parts, selection)
    if #ctx_after > 0 then
      table.insert(parts, "")
      table.insert(parts, "Context after selection (DO NOT reproduce this):")
      table.insert(parts, table.concat(ctx_after, "\n"))
    end
    if user_prompt ~= "" then
      table.insert(parts, "")
      table.insert(parts, "Instruction: " .. user_prompt)
    end
    local prompt = table.concat(parts, "\n")

    local stop_spinner = start_spinner(bufnr, start_line, end_line)

    local profile = config.options.active_profile
    local use_continue = not M._skip_continue
    M._skip_continue = false

    local cmd = { claude_bin }
    if config.options.bare then table.insert(cmd, "--bare") end
    if profile and profile.model  then vim.list_extend(cmd, { "--model",  profile.model }) end
    if profile and profile.effort then vim.list_extend(cmd, { "--effort", profile.effort }) end
    if use_continue then table.insert(cmd, "--continue") end
    vim.list_extend(cmd, { "--output-format", "json", "--print", prompt })

    vim.system(
      cmd,
      { text = true },
      vim.schedule_wrap(function(result)
        stop_spinner()

        if result.code ~= 0 or (result.stdout or "") == "" then
          vim.notify(
            string.format("novibe: exit %d — %s", result.code, vim.trim(result.stderr or "")),
            vim.log.levels.ERROR
          )
          return
        end

        local response, usage = util.parse_claude_output(result.stdout)

        -- splice the code replacement
        if response.code and response.code ~= vim.NIL then
          local new_lines = vim.split(vim.trim(response.code), "\n", { plain = true })
          vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, new_lines)
          M._last_fill = { original = vim.trim(response.code), bufnr = bufnr, start_line = start_line }
        end

        M._session_count = M._session_count + 1

        if usage then
          M._session_cost = M._session_cost + (usage.cost_usd or 0)
          M._last_usage   = usage
          pcall(function() require("lualine").refresh() end)
        end

        if M._session_count == SESSION_WARN_AFTER then
          vim.notify(
            string.format("novibe: %d fills in this session — context is getting long. Run :NovibeReset to start fresh.", SESSION_WARN_AFTER),
            vim.log.levels.WARN
          )
        end

        local has_changes = response.changes and #response.changes > 0
        local has_message = response.message and response.message ~= vim.NIL

        -- out-of-scope changes always go through the review float — never auto-apply
        if has_changes or has_message then
          chat.open(response, claude_bin)
        end
      end)
    )
  end, { stats = input_stats })
end

return M
