local M = {}

local config    = require("novibe.config")
local input     = require("novibe.input")
local no_vibe   = require("novibe.no_vibe")
local learn     = require("novibe.learn")
local providers = require("novibe.providers")

local ns = vim.api.nvim_create_namespace("novibe_act2")

-- Per-buffer state: [bufnr] = { token, top_id, bot_id, mode, ... }
-- mode: "review" | "accepted" | "teach"
local _states = {}

local spinner_frames   = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local loading_messages = {
  "cooking…", "typing so you don't have to…", "filling the blanks…",
  "no vibes, just work…", "staying in scope…", "on it…",
  "decoding your skeleton…", "just the implementation…",
}

-- ─── utilities ────────────────────────────────────────────────────────────────

local function feedkeys(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
end

local function get_keys()
  return (config.options.act2 and config.options.act2.keys) or {}
end

-- ─── extmark helpers ──────────────────────────────────────────────────────────

-- Returns current 1-indexed {start, end} lines of the scope from extmarks.
-- Extmarks track across buffer edits so this stays accurate after splicing.
local function get_scope(bufnr, s)
  local top = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, s.top_id, {})
  local bot = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, s.bot_id, {})
  if not top or #top == 0 or not bot or #bot == 0 then return nil, nil end
  return top[1] + 1, bot[1] + 1
end

local function cursor_in_scope(bufnr, s)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local sl, el = get_scope(bufnr, s)
  if not sl then return false end
  return row >= sl and row <= el
end

-- Update virt_lines on the two anchor extmarks without moving them.
local function set_virt(bufnr, s, top_virt, bot_virt)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local sl, el = get_scope(bufnr, s)
  if not sl then return end
  vim.api.nvim_buf_set_extmark(bufnr, ns, sl - 1, 0,
    { id = s.top_id, virt_lines = top_virt, virt_lines_above = true })
  vim.api.nvim_buf_set_extmark(bufnr, ns, el - 1, 0,
    { id = s.bot_id, virt_lines = bot_virt })
end

-- ─── virt_lines content ───────────────────────────────────────────────────────

local function vl(text) return { { { text, "Comment" } } } end

local function review_vl(keys)
  local cr = keys.accept   or "<CR>"
  local uu = keys.undo     or "U"
  local rr = keys.reprompt or "<leader>r"
  local tt = keys.teach    or "<leader>t"
  return vl("  " .. cr .. " accept  ·  " .. uu .. " undo  ·  " .. rr .. " re-prompt  ·  " .. tt .. " teach")
end

local function teach_vl(keys)
  local tt = keys.teach or "<leader>t"
  local uu = keys.undo  or "U"
  return vl("  edit in scope  ·  " .. tt .. " done  ·  " .. uu .. " cancel")
end


-- ─── out-of-scope scratch window ──────────────────────────────────────────────

local function show_changes(changes)
  if not changes or #changes == 0 then return nil, nil end

  local lines = { "  Out-of-scope changes (apply manually)  ", "" }
  for i, ch in ipairs(changes) do
    table.insert(lines, string.format("[%d] %s — %s", i, ch.file or "?", ch.description or ""))
    if ch.action then
      table.insert(lines, "    action: " .. ch.action)
    end
    if ch.find and ch.find ~= "" then
      table.insert(lines, "    find:")
      for _, l in ipairs(vim.split(ch.find, "\n", { plain = true })) do
        table.insert(lines, "      " .. l)
      end
    end
    if ch.replace and ch.replace ~= "" then
      table.insert(lines, "    replace:")
      for _, l in ipairs(vim.split(ch.replace, "\n", { plain = true })) do
        table.insert(lines, "      " .. l)
      end
    end
    table.insert(lines, "")
  end

  local sbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[sbuf].buftype   = "nofile"
  vim.bo[sbuf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
  vim.bo[sbuf].modifiable = false

  local cur_win = vim.api.nvim_get_current_win()
  vim.cmd("botright 12split")
  local swin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(swin, sbuf)
  vim.wo[swin].number         = false
  vim.wo[swin].relativenumber = false
  vim.wo[swin].wrap           = false
  vim.wo[swin].signcolumn     = "no"
  vim.wo[swin].statusline     = "  novibe  out-of-scope changes · q close"
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(swin) then
      vim.api.nvim_win_close(swin, true)
    end
  end, { buffer = sbuf, nowait = true })
  vim.api.nvim_set_current_win(cur_win)

  return swin, sbuf
end

-- ─── state lifecycle ──────────────────────────────────────────────────────────

local function clear_state(bufnr)
  local s = _states[bufnr]
  if not s then return end
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, s.top_id)
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, s.bot_id)
    local keys = get_keys()
    for _, k in ipairs({ keys.accept or "<CR>", keys.undo or "U",
                         keys.reprompt or "<leader>r", keys.teach or "<leader>t" }) do
      pcall(vim.keymap.del, "n", k, { buffer = bufnr })
    end
  end
  if s.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
  end
  _states[bufnr] = nil
end

-- ─── actions ──────────────────────────────────────────────────────────────────

-- <CR>: code is already in buffer — show out-of-scope scratch (if any) and done.
-- No teach virt remains; user did not ask to teach.
local function do_confirm(bufnr, s)
  if #s.response.changes > 0 then
    show_changes(s.response.changes)
  end
  clear_state(bufnr)
end

-- First <leader>t: show out-of-scope scratch (if any), enter edit mode.
local function enter_teach(bufnr, s)
  if #s.response.changes > 0 then
    show_changes(s.response.changes)
  end
  s.mode = "teach"
  local keys = get_keys()
  set_virt(bufnr, s, teach_vl(keys), teach_vl(keys))
end

-- Second <leader>t press: open reason float, compute diff, call learn.teach.
local function do_teach_done(bufnr, s)
  local sl, el = get_scope(bufnr, s)
  if not sl then clear_state(bufnr); return end

  local current_lines = vim.api.nvim_buf_get_lines(bufnr, sl - 1, el, false)
  local current    = table.concat(current_lines, "\n")
  local original   = s.teach_original
  local filename   = vim.api.nvim_buf_get_name(bufnr)
  local profile    = config.options.active_profile
  local provider   = providers.get(profile and profile.provider)
  local bin        = provider.find_bin()
  local auto_after = config.options.learn and config.options.learn.auto_extract_after

  -- temporarily restore review virt while reason float is open
  local keys = get_keys()
  s.mode = "review"
  set_virt(bufnr, s, review_vl(keys), review_vl(keys))

  input.open(function(reason)
    if not reason or reason == "" then
      -- user cancelled: restore teach virt so they can try again
      if _states[bufnr] then
        s.mode = "teach"
        set_virt(bufnr, s, teach_vl(keys), teach_vl(keys))
      end
      return
    end
    if not bin then
      vim.notify("novibe act2: provider binary not found — teach saved without auto-distill", vim.log.levels.WARN)
    end
    learn.teach(
      (original ~= current) and original or nil,
      current,
      reason,
      filename,
      provider,
      bin,
      auto_after,
      profile
    )
    clear_state(bufnr)
  end, { profile = profile })
end

-- ─── keymaps ──────────────────────────────────────────────────────────────────

local function setup_keymaps(bufnr, s)
  local keys         = get_keys()
  local accept_key   = keys.accept   or "<CR>"
  local undo_key     = keys.undo     or "U"
  local reprompt_key = keys.reprompt or "<leader>r"
  local teach_key    = keys.teach    or "<leader>t"
  local bopts        = { buffer = bufnr, nowait = true }

  -- <CR>: confirm — show out-of-scope scratch, done (no teach virt remains)
  vim.keymap.set("n", accept_key, function()
    if not cursor_in_scope(bufnr, s) then feedkeys(accept_key); return end
    if s.mode == "review" then do_confirm(bufnr, s)
    else feedkeys(accept_key) end
  end, bopts)

  -- U: undo AI code (restore original) or cancel teach
  vim.keymap.set("n", undo_key, function()
    if not cursor_in_scope(bufnr, s) then feedkeys(undo_key); return end
    if s.mode == "teach" then
      -- cancel teach: same result as <CR> — code stays, scratch stays, state clears
      clear_state(bufnr)
    else
      -- restore original lines and dismiss
      local sl, el = get_scope(bufnr, s)
      if sl then
        pcall(vim.api.nvim_buf_set_lines, bufnr, sl - 1, el, false, s.original_lines)
      end
      clear_state(bufnr)
    end
  end, bopts)

  -- <leader>r: restore original lines and re-open input float pre-filled
  vim.keymap.set("n", reprompt_key, function()
    if not cursor_in_scope(bufnr, s) then feedkeys(reprompt_key); return end
    if s.mode == "teach" then feedkeys(reprompt_key); return end
    local sl, el = get_scope(bufnr, s)
    local orig_el   = s.orig_end_line
    local last_prompt = s.last_prompt
    if sl then
      pcall(vim.api.nvim_buf_set_lines, bufnr, sl - 1, el, false, s.original_lines)
    end
    clear_state(bufnr)
    M.fill(sl, orig_el, bufnr, last_prompt)
  end, bopts)

  -- <leader>t: enter teach mode (phase 1) or capture diff+reason (phase 2)
  vim.keymap.set("n", teach_key, function()
    if not cursor_in_scope(bufnr, s) then feedkeys(teach_key); return end
    if s.mode == "review" then
      enter_teach(bufnr, s)
    elseif s.mode == "teach" then
      do_teach_done(bufnr, s)
    end
  end, bopts)
end

-- ─── spinner ──────────────────────────────────────────────────────────────────

local function start_spinner(bufnr, start_line, end_line)
  local frame = 1
  local msg   = loading_messages[math.random(#loading_messages)]
  local v     = { { { spinner_frames[frame] .. "  " .. msg, "Comment" } } }

  local top_id = vim.api.nvim_buf_set_extmark(bufnr, ns, start_line - 1, 0,
    { virt_lines = v, virt_lines_above = true })
  local bot_id = vim.api.nvim_buf_set_extmark(bufnr, ns, end_line - 1, 0,
    { virt_lines = v })

  local timer = vim.uv.new_timer()
  timer:start(80, 80, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then timer:stop(); timer:close(); return end
    frame = (frame % #spinner_frames) + 1
    local vv = { { { spinner_frames[frame] .. "  " .. msg, "Comment" } } }
    vim.api.nvim_buf_set_extmark(bufnr, ns, start_line - 1, 0,
      { id = top_id, virt_lines = vv, virt_lines_above = true })
    vim.api.nvim_buf_set_extmark(bufnr, ns, end_line - 1, 0,
      { id = bot_id, virt_lines = vv })
  end))

  return function()
    timer:stop(); timer:close()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_del_extmark(bufnr, ns, top_id)
      vim.api.nvim_buf_del_extmark(bufnr, ns, bot_id)
    end
  end
end

-- ─── main entry point ─────────────────────────────────────────────────────────

-- line1, line2: 1-indexed selection (nil = use visual marks '<,'>)
-- bufnr_arg:    buffer to operate on (nil = current)
-- initial_prompt: pre-fill the input float (used by re-prompt)
function M.fill(line1, line2, bufnr_arg, initial_prompt)
  local active_profile = config.options.active_profile
  local provider = providers.get(active_profile and active_profile.provider)
  local bin = provider.find_bin()
  if not bin then
    vim.notify("novibe: " .. provider.name .. " binary not found", vim.log.levels.ERROR)
    return
  end

  if line1 == nil or line2 == nil then
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  end

  local bufnr      = bufnr_arg or vim.api.nvim_get_current_buf()
  local start_line = line1 or vim.fn.getpos("'<")[2]
  local end_line   = line2 or vim.fn.getpos("'>")[2]
  local total      = vim.api.nvim_buf_line_count(bufnr)

  local original_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local selection      = table.concat(original_lines, "\n")
  local ctx_before     = vim.api.nvim_buf_get_lines(bufnr, math.max(0, start_line - 11), start_line - 1, false)
  local ctx_after      = vim.api.nvim_buf_get_lines(bufnr, end_line, math.min(total, end_line + 10), false)
  local filename       = vim.api.nvim_buf_get_name(bufnr)

  -- preload no_vibe while user types (avoids blocking git calls in the callback)
  local no_vibe_txt = no_vibe.load(filename)

  -- clear any prior state for this buffer
  if _states[bufnr] then clear_state(bufnr) end

  -- token guards against a stale vim.system callback overwriting a newer fill
  local token = {}
  _states[bufnr] = { token = token }

  input.open(function(user_prompt)
    if user_prompt == nil then
      -- cancelled: clear the token placeholder
      if _states[bufnr] and _states[bufnr].token == token then
        _states[bufnr] = nil
      end
      return
    end

    local parts = {
      config.options.system_prompt,
      no_vibe_txt and ("\nProject conventions:\n" .. no_vibe_txt) or "",
      "",
    }

    local ctx_before_top = math.max(1, start_line - 10)
    local enclosing = require("novibe.context").enclosing(bufnr, start_line, ctx_before_top)
    if enclosing then table.insert(parts, enclosing); table.insert(parts, "") end
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
    local diag_txt = require("novibe.diag").format(bufnr, start_line, end_line)
    if diag_txt then table.insert(parts, ""); table.insert(parts, diag_txt) end
    if user_prompt ~= "" then
      table.insert(parts, "")
      table.insert(parts, "Instruction: " .. user_prompt)
    end
    local prompt = table.concat(parts, "\n")

    local stop_spinner = start_spinner(bufnr, start_line, end_line)

    local cmd = provider.build_cmd(bin, prompt, {
      profile      = active_profile,
      bare         = config.options.bare,
      use_continue = false,  -- act2 is always a fresh session
      session_id   = nil,
      stream       = provider.streaming,
    })

    local sctx = { raw = "" }
    local sys_opts = { text = true }
    if provider.streaming then
      sys_opts.stdout = function(_, data)
        if data then sctx.raw = sctx.raw .. data end
      end
    end

    vim.system(cmd, sys_opts, vim.schedule_wrap(function(result)
      stop_spinner()

      -- discard if a newer fill was started for this buffer
      if not _states[bufnr] or _states[bufnr].token ~= token then return end

      local stdout = provider.streaming and sctx.raw or (result.stdout or "")
      if result.code ~= 0 or vim.trim(stdout) == "" then
        vim.notify(
          string.format("novibe act2: exit %d — %s", result.code, vim.trim(result.stderr or "")),
          vim.log.levels.ERROR
        )
        _states[bufnr] = nil
        return
      end

      local response, _usage = provider.parse_output(stdout)
      -- normalize vim.NIL (JSON null) fields so later code can assume clean types
      if type(response.code)    ~= "string" then response.code    = "" end
      if type(response.message) ~= "string" then response.message = nil end
      if type(response.changes) ~= "table"  then response.changes = {} end

      local ai_code = vim.trim(response.code)
      if ai_code == "" then
        vim.notify(
          "novibe act2: " .. ((response and response.message) or "AI returned no code"),
          vim.log.levels.WARN
        )
        _states[bufnr] = nil
        return
      end

      if response.message and response.message ~= "" then
        vim.notify("novibe: " .. response.message, vim.log.levels.INFO)
      end

      -- Splice AI code into buffer immediately so the user sees it.
      local code_lines = vim.split(ai_code, "\n", { plain = true })
      local ok = pcall(vim.api.nvim_buf_set_lines, bufnr, start_line - 1, end_line, false, code_lines)
      if not ok then
        vim.notify("novibe act2: buffer is not modifiable", vim.log.levels.ERROR)
        _states[bufnr] = nil
        return
      end

      -- Extmarks anchor above and below the newly written code.
      local top_id = vim.api.nvim_buf_set_extmark(bufnr, ns, start_line - 1, 0, {})
      local bot_id = vim.api.nvim_buf_set_extmark(bufnr, ns, start_line - 1 + #code_lines - 1, 0, {})

      local s = {
        token          = token,
        start_line     = start_line,
        end_line       = start_line - 1 + #code_lines,
        orig_end_line  = end_line,   -- original selection end for reprompt
        original_lines = original_lines,
        response       = response,
        ai_code        = ai_code,
        last_prompt    = user_prompt,
        top_id         = top_id,
        bot_id         = bot_id,
        mode           = "review",
        teach_original = ai_code,
        augroup        = nil,
      }
      _states[bufnr] = s

      local keys = get_keys()
      set_virt(bufnr, s, review_vl(keys), review_vl(keys))

      local ag = vim.api.nvim_create_augroup("novibe_act2_" .. bufnr, { clear = true })
      s.augroup = ag
      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer   = bufnr,
        group    = ag,
        once     = true,
        callback = function() clear_state(bufnr) end,
      })

      setup_keymaps(bufnr, s)
    end))
  end, { profile = active_profile, initial = initial_prompt })
end

return M
