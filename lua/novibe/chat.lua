local apply = require("novibe.apply")
local learn = require("novibe.learn")

local M = {}

local MARKER     = "── <CR> accept  ·  type feedback + :w to send ──────────────────────────────────"
local MARKER_MSG = "── type reply + :w to send ─────────────────────────────────────────────────────"

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local CONFIRM = {
  ok=1, yes=1, y=1, yep=1, sure=1, apply=1, go=1,
  ["do it"]=1, ["go ahead"]=1, confirm=1, ["looks good"]=1,
  ["lgtm"]=1, ["ship it"]=1,
}

-- Track the active fill window so :NovibeActReviewFocus can jump to it.
local _fill_win = nil

local function is_confirm(text)
  return CONFIRM[vim.trim(text):lower()] ~= nil
end

-- AI/JSON parsers may yield vim.NIL or non-tables here; coerce to a real list
-- so `#changes` and `ipairs(changes)` behave as expected downstream.
local function normalize_changes(c)
  if type(c) ~= "table" then return {} end
  return c
end

local CONTEXT_LINES = 3

local function split_width()
  -- 40% of editor width, clamped to a comfortable reading range
  return math.min(math.max(math.floor(vim.o.columns * 0.4), 50), 90)
end

-- Return N lines before/after a selection in a buffer (0-based API, 1-based args).
local function buf_context(bufnr, start_line, end_line, n)
  if not vim.api.nvim_buf_is_valid(bufnr) then return {}, {} end
  local total = vim.api.nvim_buf_line_count(bufnr)
  local before = vim.api.nvim_buf_get_lines(bufnr, math.max(0, start_line - 1 - n), start_line - 1, false)
  local after  = vim.api.nvim_buf_get_lines(bufnr, end_line, math.min(total, end_line + n), false)
  return before, after
end

-- Search file for find_text and return N context lines before/after it.
-- Also returns match_start (1-based line number) so callers can render line numbers.
-- Returns empty tables + nil if the file can't be read or find_text isn't located.
local function file_context(filepath, find_text, n)
  local abs = vim.fn.fnamemodify(filepath, ":p")
  local ok, content = pcall(vim.fn.readfile, abs)
  if not ok or not content then return {}, {}, nil end
  local find_lines = vim.split(vim.trim(find_text), "\n", { plain = true })
  local nf = #find_lines
  local match_start = nil
  for i = 1, #content - nf + 1 do
    local hit = true
    for j = 1, nf do
      if vim.trim(content[i + j - 1]) ~= vim.trim(find_lines[j]) then hit = false; break end
    end
    if hit then match_start = i; break end
  end
  if not match_start then return {}, {}, nil end
  local match_end = match_start + nf - 1
  local before, after = {}, {}
  for i = math.max(1, match_start - n), match_start - 1 do table.insert(before, content[i]) end
  for i = match_end + 1, math.min(#content, match_end + n) do table.insert(after, content[i]) end
  return before, after, match_start
end

-- Build lines + highlight specs [{line (0-based), hl}] for the read-only section.
-- `inner_w` is the visible width of the chat window; the diff block's closing
-- rule is drawn to fit so it doesn't wrap awkwardly in narrow splits.
local function render(response, inner_w)
  inner_w = math.max(inner_w or 60, 20)
  local lines = {}
  local hls   = {}

  local function push(line, hl)
    table.insert(lines, line)
    if hl then table.insert(hls, { #lines - 1, hl }) end
  end

  if response.message and response.message ~= vim.NIL and response.message ~= "" then
    for _, l in ipairs(vim.split(response.message, "\n", { plain = true })) do
      push(l)
    end
    push("")
  end

  local changes = response.changes or {}
  local total = #changes
  for i, change in ipairs(changes) do
    local num = total > 1 and string.format("[%d/%d] ", i, total) or ""
    push("┌─ " .. num .. change.file .. "  [" .. (change.action or "replace") .. "]", "Title")
    push("│  " .. change.description, "Comment")
    push("│")
    for _, l in ipairs(vim.split(vim.trim(change.find), "\n", { plain = true })) do
      push("  - " .. l, "DiffDelete")
    end
    for _, l in ipairs(vim.split(vim.trim(change.replace), "\n", { plain = true })) do
      push("  + " .. l, "DiffAdd")
    end
    push("└" .. string.rep("─", inner_w - 2), "Comment")
    push("")
  end

  return lines, hls
end

local function apply_hls(buf_ns, bufnr, hls)
  vim.api.nvim_buf_clear_namespace(bufnr, buf_ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(bufnr, buf_ns, h[2], h[1], 0, -1)
  end
end

local function schema_reminder(pending)
  local base = '\n\n[Respond ONLY in JSON: {"message":...,"changes":[...],"done":true/false}]'
  if not pending or #pending == 0 then return base end
  local lines = { base, "\n[IMPORTANT: none of the previously proposed changes have been applied to any file yet — they are still pending. When you generate revised changes, the \"find\" field must match the CURRENT unmodified file content, not code from your previous proposals. Files still pending:" }
  for _, c in ipairs(pending) do
    table.insert(lines, "  - " .. c.file .. (c.description and (": " .. c.description) or ""))
  end
  table.insert(lines, "]")
  return table.concat(lines, "\n")
end

local TITLE_IDLE        = "%#Title# novibe %#Normal#  ·  :w send  ·  <CR> apply  ·  q quit"
local TITLE_DONE        = "%#DiagnosticOk# ✓ done  %#Normal#·  :w send  ·  <CR> apply  ·  q quit"
local TITLE_GENERATING  = "%#Title# novibe %#Normal#  ·  ⠋ generating…  ·  q cancel"

function M.open(initial_response, opts)
  local bin        = opts.bin
  local provider   = opts.provider
  local session_id = opts.session_id
  -- store changes so confirmations can apply locally without a round-trip
  local pending_changes = normalize_changes(initial_response.changes)

  local ns  = vim.api.nvim_create_namespace("novibe_chat")
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, "novibe://chat/" .. vim.uv.hrtime())
  vim.bo[buf].buftype   = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false

  -- open as a right-side vertical split so the in-scope code stays visible
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, split_width())

  vim.wo[win].wrap       = true
  vim.wo[win].linebreak  = true
  vim.wo[win].number     = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false
  vim.wo[win].winfixwidth = true

  local function set_winbar(text)
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].winbar = text
    end
  end

  set_winbar(TITLE_IDLE)

  local function inner_width()
    if vim.api.nvim_win_is_valid(win) then
      return vim.api.nvim_win_get_width(win) - 2
    end
    return 60
  end

  local done    = false
  local current_job = nil
  local job_token   = 0
  local active_stop = nil

  local function set_content(r_lines, r_hls)
    local content = vim.list_extend(vim.deepcopy(r_lines), { MARKER, "" })
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    apply_hls(ns, buf, r_hls)

    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { #content, 0 })
      -- only enter insert mode if chat is focused; don't yank focus from the
      -- code window the user might be reading
      if vim.api.nvim_get_current_win() == win then
        vim.cmd("startinsert")
      end
    end
  end

  local response_lines, hls = render(initial_response, inner_width())
  set_content(response_lines, hls)

  local function close()
    done = true
    if current_job then
      pcall(function() current_job:kill(9) end)
      current_job = nil
    end
    if vim.api.nvim_get_current_win() == win then
      vim.cmd("stopinsert")
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function extract_reply()
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i = #all, 1, -1 do
      if all[i] == MARKER then
        local reply_lines = vim.list_slice(all, i + 1)
        return vim.trim(table.concat(reply_lines, "\n"))
      end
    end
    return ""
  end

  local function start_spinner()
    local frame = 1
    local timer = vim.uv.new_timer()
    timer:start(80, 80, vim.schedule_wrap(function()
      if not vim.api.nvim_win_is_valid(win) then timer:stop(); timer:close(); return end
      frame = (frame % #spinner_frames) + 1
      set_winbar("%#Title# novibe %#Normal#  ·  " .. spinner_frames[frame] .. " thinking…  ·  q quit")
    end))
    return function()
      timer:stop(); timer:close()
      set_winbar(TITLE_IDLE)
    end
  end

  local function send()
    if done then return end
    local reply = extract_reply()

    -- local confirmation: apply stored changes without another round-trip
    if is_confirm(reply) and #pending_changes > 0 then
      apply.apply_all(pending_changes)
      close()
      return
    end

    -- Supersede any in-flight send (see open_fill for rationale).
    if current_job then pcall(function() current_job:kill(9) end); current_job = nil end
    if active_stop then active_stop(); active_stop = nil end
    job_token = job_token + 1
    local my_token = job_token

    local stop = start_spinner()
    active_stop = stop

    local reminder = schema_reminder(pending_changes)
    local msg = reply ~= "" and (reply .. reminder) or ("continue" .. reminder)

    local cmd = provider.build_cmd(bin, msg, {
      profile      = nil,           -- follow-ups inherit the original session's model/effort
      bare         = false,
      use_continue = true,          -- claude: --continue
      session_id   = session_id,    -- opencode: --session ID
    })

    current_job = vim.system(
      cmd,
      { text = true },
      vim.schedule_wrap(function(result)
        if my_token ~= job_token then return end
        current_job = nil
        if active_stop == stop then active_stop = nil end
        stop()
        if not vim.api.nvim_win_is_valid(win) then return end

        if result.code ~= 0 or (result.stdout or "") == "" then
          vim.notify(
            string.format("novibe: exit %d — %s", result.code, vim.trim(result.stderr or "")),
            vim.log.levels.ERROR
          )
          return
        end

        local response, usage = provider.parse_output(result.stdout)
        if usage and usage.session_id then session_id = usage.session_id end

        if usage then
          local parts = {}
          if usage.cost_usd then table.insert(parts, string.format("$%.4f", usage.cost_usd)) end
          if usage.input_tokens and usage.context_window and usage.context_window > 0 then
            table.insert(parts, string.format("ctx %d%%", math.floor(usage.input_tokens / usage.context_window * 100)))
          end
          if #parts > 0 then
            local info = table.concat(parts, " · "):gsub("%%", "%%%%")
            set_winbar("%#Title# novibe %#Normal#  " .. info .. "  ·  :w send  ·  q quit")
          end
        end

        local new_changes = normalize_changes(response.changes)
        if #new_changes > 0 then pending_changes = new_changes end

        local new_lines, new_hls = render(response, inner_width())
        set_content(new_lines, new_hls)
        if response.done then
          set_winbar(TITLE_DONE)
        end
      end)
    )
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      vim.bo[buf].modified = false
      send()
    end,
  })

  local function confirm()
    if done then return end
    if #pending_changes > 0 then
      apply.apply_all(pending_changes)
    end
    close()
  end

  local function smart_insert()
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local marker_row = nil
    for i = #all, 1, -1 do
      if all[i] == MARKER then marker_row = i; break end
    end
    if not marker_row then vim.cmd("startinsert"); return end
    local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
    if cursor_row > marker_row then
      vim.cmd("startinsert")
    else
      vim.api.nvim_win_set_cursor(win, { #all, 0 })
      vim.cmd("startinsert!")
    end
  end

  local kopts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q",     close,        kopts)
  vim.keymap.set("n", "<Esc>", close,        kopts)
  vim.keymap.set("n", "<CR>",  confirm,      kopts)
  vim.keymap.set("n", "i",     smart_insert, kopts)
  vim.keymap.set("n", "a",     smart_insert, kopts)
  vim.keymap.set("n", "A",     smart_insert, kopts)
  vim.keymap.set("n", "I",     smart_insert, kopts)
  vim.keymap.set("n", "o",     smart_insert, kopts)
  vim.keymap.set("n", "O",     smart_insert, kopts)
end

-- Open the fill-preview chat. Returns { push, finalize, cancel }.
--   push(partial)       — update displayed code during streaming (no input yet)
--   finalize(resp, use) — streaming done; build question queue, render Q1
--   cancel()            — close without applying (on error)
-- pending: { bufnr, start_line, end_line, on_apply(code) }
-- opts:    { bin, provider, session_id, on_session_update(sid) }
--
-- After finalize, the AI response is split into a queue of "questions":
--   1. In-scope code (if any)  — apply replaces the original selection
--   2..N. Each out-of-scope change — apply runs apply.apply_all on that one
-- Exactly ONE question is rendered at a time, with a "[k/N]" indicator in the
-- winbar. <CR> applies the head; `s` skips it; `:w <text>` asks the AI to
-- revise (the response replaces the remaining queue); `:w all` applies every
-- remaining question and closes; `q` quits.
function M.open_fill(pending, opts)
  local bin      = opts.bin
  local provider = opts.provider
  local session_id = opts.session_id

  local ns  = vim.api.nvim_create_namespace("novibe_fill")
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, "novibe://fill/" .. vim.uv.hrtime())
  vim.bo[buf].buftype   = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false

  -- Start treesitter (not filetype) so the streaming push phase has syntax
  -- highlighting. render_q stops/restarts it per-question, so there's no
  -- conflict between the source file's language and a change-Q's target lang.
  local init_ft = pending.bufnr and vim.bo[pending.bufnr].filetype or ""
  if init_ft ~= "" then
    local init_lang = (vim.treesitter.language.get_lang and vim.treesitter.language.get_lang(init_ft)) or init_ft
    pcall(vim.treesitter.start, buf, init_lang)
  end

  local prev_win = vim.api.nvim_get_current_win()
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, split_width())
  vim.api.nvim_set_current_win(prev_win)  -- no focus steal
  _fill_win = win

  vim.wo[win].wrap        = false
  vim.wo[win].number      = false
  vim.wo[win].signcolumn  = "no"
  vim.wo[win].cursorline  = false
  vim.wo[win].winfixwidth = true

  local function set_winbar(text)
    if vim.api.nvim_win_is_valid(win) then vim.wo[win].winbar = text end
  end
  set_winbar(TITLE_GENERATING)

  -- Animate the winbar during initial generation (stopped in finalize/close).
  local gen_frame = 1
  local gen_timer = vim.uv.new_timer()
  gen_timer:start(80, 80, vim.schedule_wrap(function()
    if not vim.api.nvim_win_is_valid(win) then gen_timer:stop(); gen_timer:close(); return end
    gen_frame = (gen_frame % #spinner_frames) + 1
    set_winbar("%#Title# novibe %#Normal#  ·  " .. spinner_frames[gen_frame] .. " generating…  ·  q cancel")
  end))
  local function stop_gen_spinner() pcall(function() gen_timer:stop(); gen_timer:close() end) end

  local pending_ns  = vim.api.nvim_create_namespace("novibe_pending")

  local function set_pending_indicator()
    if not (pending.bufnr and vim.api.nvim_buf_is_valid(pending.bufnr)) then return end
    vim.api.nvim_buf_set_extmark(pending.bufnr, pending_ns, pending.end_line - 1, 0, {
      virt_lines = {
        { { "  ▸ novibe: review & accept in chat  ·  <CR> apply  ·  s skip  ·  q quit", "DiagnosticWarn" } },
      },
      virt_lines_above = false,
    })
  end

  local function clear_pending_indicator()
    if pending.bufnr and vim.api.nvim_buf_is_valid(pending.bufnr) then
      vim.api.nvim_buf_clear_namespace(pending.bufnr, pending_ns, 0, -1)
    end
  end

  local done            = false
  local finalized       = false
  local sending_enabled = false
  local current_job     = nil
  -- Monotonic token. Each send() bumps it; the in-flight callback checks its
  -- captured token before mutating state, so a superseding send() never gets
  -- its queue stomped by the older job's late callback.
  local job_token       = 0
  local active_stop     = nil  -- spinner stop for the in-flight job, if any
  -- Queue of pending questions. Each item is one of:
  --   { type = "code",   code = "..." }     — replaces the original selection
  --   { type = "change", change = {...} }   — one apply.lua change spec
  local questions       = {}
  local total           = 0    -- denominator for "[k/N]" display; resets on AI revision
  local last_message    = nil  -- AI's last `response.message`, rendered above the current Q

  local function current_idx() return total - #questions + 1 end

  local function inner_w()
    return vim.api.nvim_win_is_valid(win) and (vim.api.nvim_win_get_width(win) - 2) or 60
  end

  local function close()
    done = true
    stop_gen_spinner()
    clear_pending_indicator()
    if current_job then pcall(function() current_job:kill(9) end); current_job = nil end
    if vim.api.nvim_get_current_win() == win then vim.cmd("stopinsert") end
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if _fill_win == win then _fill_win = nil end
    -- Notify init.lua so it can kill the outer vim.system job and clear the
    -- working-buffer spinner (which lives outside the chat window).
    if opts.on_cancel then pcall(opts.on_cancel) end
  end

  -- Render the head-of-queue question + MARKER + reply area. Cursor lands at
  -- the reply area so the user can <CR> apply or `i` to type a revision.
  local function render_q()
    if done then return end
    local q = questions[1]
    if not q then close(); return end

    local idx = current_idx()
    local lines, hls = {}, {}
    local function push(line, hl)
      table.insert(lines, line)
      if hl then table.insert(hls, { #lines - 1, hl }) end
    end

    -- Render the AI's latest message inline above the current question so
    -- clarifying questions ("which FlexBox?") aren't lost in the notification log.
    if last_message and last_message ~= "" then
      local bar = "─ AI ─"
      push(bar .. string.rep("─", math.max(0, inner_w() - #bar - 1)), "Comment")
      for _, l in ipairs(vim.split(last_message, "\n", { plain = true })) do
        push("  " .. l, "DiagnosticInfo")
      end
      push(string.rep("─", inner_w() - 1), "Comment")
      push("")
    end

    if q.type == "code" then
      push(string.format("[%d/%d] In-scope code (will replace your selection):", idx, total), "Title")
      push("")
      -- Show surrounding context from the working buffer so the user knows
      -- where the new code lands (original selection as -, new code as +).
      -- No line-number prefix — treesitter needs clean lines to parse correctly.
      local orig_lines = {}
      if pending.bufnr and vim.api.nvim_buf_is_valid(pending.bufnr) then
        orig_lines = vim.api.nvim_buf_get_lines(
          pending.bufnr, pending.start_line - 1, pending.end_line, false)
      end
      local ctx_before, ctx_after = {}, {}
      if pending.bufnr and vim.api.nvim_buf_is_valid(pending.bufnr) then
        ctx_before, ctx_after = buf_context(pending.bufnr, pending.start_line, pending.end_line, CONTEXT_LINES)
      end
      for _, l in ipairs(ctx_before)  do push(l, "Comment")    end
      for _, l in ipairs(orig_lines)  do push(l, "DiffDelete") end
      for _, l in ipairs(vim.split(q.code or "", "\n", { plain = true })) do push(l, "DiffAdd") end
      for _, l in ipairs(ctx_after)   do push(l, "Comment")    end
      push("└" .. string.rep("─", inner_w() - 2), "Comment")
      set_winbar(string.format(
        "%%#Title# novibe [%d/%d] %%#Normal# in-scope  ·  <CR> apply  ·  s skip  ·  :w feedback  ·  q quit",
        idx, total
      ))
    elseif q.type == "change" then
      local ch = q.change
      push(string.format("[%d/%d] Out-of-scope: %s  [%s]",
        idx, total, ch.file or "?", ch.action or "replace"), "Title")
      local abs = ch.file and vim.fn.fnamemodify(ch.file, ":p") or ""
      local file_exists = ch.file and ch.file ~= "" and vim.fn.filereadable(abs) == 1
      if ch.action == "delete" then
        -- For delete: warn if file is missing (nothing to delete), otherwise
        -- show the full file as removed lines so the user sees what goes away.
        if not file_exists then
          push("│  ⚠ file does not exist — nothing to delete.", "DiagnosticError")
        else
          push("│  ⚠ This file will be permanently deleted.", "DiagnosticWarn")
        end
        if ch.description and ch.description ~= "" then
          push("│  " .. ch.description, "Comment")
        end
        push("│")
        if file_exists then
          local file_lines = vim.fn.readfile(abs)
          for _, l in ipairs(file_lines) do push(l, "DiffDelete") end
        end
      else
        -- Surface hallucinated file paths up-front so the user doesn't waste a
        -- <CR> on something apply.lua will reject.
        if not file_exists and ch.action ~= "create" then
          push("│  ⚠ file does not exist — likely a hallucinated path. Revise with :w or skip with `s`.", "DiagnosticError")
        end
        if ch.description and ch.description ~= "" then
          push("│  " .. ch.description, "Comment")
        end
        push("│")
        -- Show file context around the find block so the user knows where in
        -- the file this change lands (only when find is non-empty).
        local ctx_before, ctx_after = {}, {}
        if ch.find and ch.find ~= "" and ch.file and ch.file ~= "" then
          ctx_before, ctx_after = file_context(ch.file, ch.find, CONTEXT_LINES)
        end
        local find_lines = ch.find and ch.find ~= "" and vim.split(vim.trim(ch.find), "\n", { plain = true }) or {}
        for _, l in ipairs(ctx_before)  do push(l, "Comment")    end
        for _, l in ipairs(find_lines)  do push(l, "DiffDelete") end
        if ch.replace and ch.replace ~= "" then
          for _, l in ipairs(vim.split(vim.trim(ch.replace), "\n", { plain = true })) do
            push(l, "DiffAdd")
          end
        end
        for _, l in ipairs(ctx_after)   do push(l, "Comment")    end
      end
      push("└" .. string.rep("─", inner_w() - 2), "Comment")
      set_winbar(string.format(
        "%%#WarningMsg# [%d/%d] out-of-scope %%#Normal# ·  <CR> apply  ·  s skip  ·  :w feedback  ·  :w all  ·  q quit",
        idx, total
      ))
    else
      -- message-only: last_message banner already rendered above; just set winbar
      set_winbar("%%#Title# novibe %%#Normal# AI message  ·  :w reply  ·  q quit")
    end

    local marker  = (q.type == "message") and MARKER_MSG or MARKER
    local content = vim.list_extend(vim.deepcopy(lines), { "", marker, "" })
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(hls) do
      vim.api.nvim_buf_add_highlight(buf, ns, h[2], h[1], 0, -1)
    end
    -- Treesitter highlighting: all renders strip line-number prefixes above so
    -- the parser sees clean code. DiffAdd/DiffDelete backgrounds still show via ns.
    pcall(vim.treesitter.stop, buf)
    local ts_ft
    if q.type == "code" then
      ts_ft = pending.bufnr and vim.api.nvim_buf_is_valid(pending.bufnr)
              and vim.bo[pending.bufnr].filetype or nil
    elseif q.type == "change" and q.change.file and q.change.file ~= "" then
      ts_ft = vim.filetype.match({ filename = q.change.file })
    end
    if ts_ft and ts_ft ~= "" then
      local ts_lang = (vim.treesitter.language.get_lang and vim.treesitter.language.get_lang(ts_ft)) or ts_ft
      pcall(vim.treesitter.start, buf, ts_lang)
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { #content, 0 })
    end
  end

  local function is_marker(line) return line == MARKER or line == MARKER_MSG end

  local function extract_reply()
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i = #all, 1, -1 do
      if is_marker(all[i]) then
        return vim.trim(table.concat(vim.list_slice(all, i + 1), "\n"))
      end
    end
    return ""
  end

  local function clear_reply()
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i = #all, 1, -1 do
      if is_marker(all[i]) then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, i, -1, false, { "" })
        vim.bo[buf].modified = false
        return
      end
    end
  end

  local function fill_spinner()
    local frame = 1
    local timer = vim.uv.new_timer()
    timer:start(80, 80, vim.schedule_wrap(function()
      if not vim.api.nvim_win_is_valid(win) then timer:stop(); timer:close(); return end
      frame = (frame % #spinner_frames) + 1
      set_winbar("%#Title# novibe %#Normal#  ·  " .. spinner_frames[frame] .. " thinking…  ·  q quit")
    end))
    return function() timer:stop(); timer:close() end
  end

  -- Apply one question. Returns true on success; false (+ notify) on failure
  -- so confirm() can stay on the question instead of silently advancing.
  local function apply_q(q)
    if q.type == "message" then return true end
    if q.type == "code" then
      if not (q.code and pending.bufnr and vim.api.nvim_buf_is_valid(pending.bufnr)) then
        vim.notify("novibe: working buffer is gone — cannot apply code", vim.log.levels.ERROR)
        return false
      end
      local new_lines = vim.split(q.code, "\n", { plain = true })
      vim.api.nvim_buf_set_lines(pending.bufnr, pending.start_line - 1, pending.end_line, false, new_lines)
      -- Keep pending in sync so a revised code-Q (from :w feedback) splices
      -- the correct range on re-apply, not the stale original end_line.
      pending.end_line = pending.start_line + #new_lines - 1
      if opts.on_apply then opts.on_apply(q.code) end
      return true
    else
      -- Use apply.apply directly so we can see the per-change error.
      local ok, err = apply.apply(q.change)
      if not ok then
        vim.notify(
          "novibe: could not apply this change — " .. (err or "unknown error")
          .. ".\nThe buffer may have changed since the AI proposed this. Revise with :w <feedback>, or skip with `s`.",
          vim.log.levels.ERROR
        )
        return false
      end
      vim.notify("novibe: applied change in " .. (q.change.file or "?"), vim.log.levels.INFO)
      return true
    end
  end

  -- Apply head-of-queue; if apply fails, stay on this question.
  local function confirm()
    if done or not finalized then return end
    local q = questions[1]
    if not q then close(); return end
    if not apply_q(q) then return end  -- stay; user can revise or skip
    table.remove(questions, 1)
    last_message = nil  -- previous AI message was about the just-applied Q
    if #questions == 0 then close() else render_q() end
  end

  -- Skip head-of-queue (don't apply); advance.
  local function skip()
    if done or not finalized then return end
    if #questions == 0 then close(); return end
    table.remove(questions, 1)
    last_message = nil
    if #questions == 0 then close() else render_q() end
  end

  local function send()
    if done or not sending_enabled then return end
    local reply = extract_reply()
    if is_confirm(reply) and (not questions[1] or questions[1].type ~= "message") then confirm(); return end

    -- ":w all" / ":w *" — apply EVERY remaining question in order. If one
    -- fails, stop on it so the user can revise or skip.
    if #questions > 0 then
      local trimmed = vim.trim(reply):lower()
      if trimmed == "all" or trimmed == "*" then
        while #questions > 0 do
          if not apply_q(questions[1]) then render_q(); return end
          table.remove(questions, 1)
        end
        close()
        return
      end
    end

    -- "#teach <reason>" — capture feedback as a note-mode teach entry without
    -- sending to AI. The reason text IS the rule; no diff needed since the user
    -- never wrote the corrected code directly (only described it in words).
    local teach_reason = reply:match("^#teach%s+(.*)")
    if teach_reason and teach_reason ~= "" then
      local filename = pending.bufnr and vim.api.nvim_buf_get_name(pending.bufnr) or ""
      learn.teach(nil, nil, teach_reason, filename, provider, bin, opts.auto_after, opts.profile)
      clear_reply()
      return
    end

    -- Supersede any in-flight send so we don't end up with stacking spinners,
    -- two AI jobs racing on the queue, or a stale callback overwriting fresh
    -- state. The kill is best-effort; the token check in the callback is the
    -- actual guard (the OS may still deliver the callback after kill).
    if current_job then pcall(function() current_job:kill(9) end); current_job = nil end
    if active_stop then active_stop(); active_stop = nil end
    job_token = job_token + 1
    local my_token = job_token

    local stop = fill_spinner()
    active_stop = stop
    local cur_q = questions[1]
    -- Anchor the AI to the question the user is reacting to.
    local hint
    if cur_q and cur_q.type == "code" then
      hint = '\n\n[User is reviewing the in-scope code. Their feedback below should revise the code (you may also revise the out-of-scope changes). Respond ONLY in JSON: {"code":...,"message":...,"changes":[...],"done":true/false}]'
    elseif cur_q and cur_q.type == "change" then
      local ch = cur_q.change
      local abs = ch.file and vim.fn.fnamemodify(ch.file, ":p") or ""
      local exists_note = ""
      if ch.file and ch.file ~= "" and vim.fn.filereadable(abs) == 0
          and ch.action ~= "create" and ch.action ~= "delete" then
        exists_note = string.format(
          ' IMPORTANT: the path "%s" does NOT exist in this project — you likely hallucinated it. Use a path that actually exists, or drop this change.',
          ch.file
        )
      end
      -- For #gen there's no in-scope code; don't tell the AI it was applied.
      local applied_note = pending.bufnr and "In-scope code already applied to the buffer. " or ""
      -- For create actions the file does not exist yet; prevent the AI from
      -- switching action to "replace" (which would fail on a missing file).
      local create_note = ch.action == "create"
        and ' The file does NOT exist yet — keep action="create" and return the full revised content in "replace" with "find":"".'
        or ""
      hint = string.format(
        '\n\n[%sUser is reviewing this out-of-scope change: file=%s, action=%s. Description: %s.%s%s Their feedback below applies to this change. Respond ONLY with revised changes JSON: {"message":...,"changes":[...],"done":true/false}. Do NOT include a "code" field.]',
        applied_note, ch.file or "?", ch.action or "replace", ch.description or "", exists_note, create_note
      )
    else
      hint = '\n\n[Respond ONLY in JSON: {"code":...,"message":...,"changes":[...],"done":true/false}]'
    end
    local cmd = provider.build_cmd(bin, (reply ~= "" and reply or "continue") .. hint, {
      profile = nil, bare = false, use_continue = true, session_id = session_id,
    })

    current_job = vim.system(cmd, { text = true }, vim.schedule_wrap(function(result)
      -- Superseded by a newer send(): silently drop this result.
      if my_token ~= job_token then return end
      current_job = nil
      if active_stop == stop then active_stop = nil end
      stop()
      if not vim.api.nvim_win_is_valid(win) then return end
      if result.code ~= 0 or (result.stdout or "") == "" then
        vim.notify(string.format("novibe: exit %d — %s", result.code, vim.trim(result.stderr or "")), vim.log.levels.ERROR)
        return
      end
      local response, usage = provider.parse_output(result.stdout)
      if usage and usage.session_id then
        session_id = usage.session_id
        if opts.on_session_update then opts.on_session_update(session_id) end
      end

      -- Rebuild the queue from the revised response. A new code-Q is only
      -- accepted if the current head WAS a code-Q (otherwise the in-scope
      -- edit is already applied and the AI was instructed not to return one).
      -- Tail questions (Q2, Q3...) that the user hasn't seen yet are preserved
      -- after the AI's revised questions so they don't silently disappear.
      local new_q = {}
      if pending.bufnr and cur_q and cur_q.type == "code"
         and response.code and response.code ~= vim.NIL and response.code ~= "" then
        table.insert(new_q, { type = "code", code = vim.trim(response.code) })
      end
      local seen_files = {}
      for _, ch in ipairs(normalize_changes(response.changes)) do
        if ch.file and ch.file ~= "" then seen_files[ch.file] = true end
        table.insert(new_q, { type = "change", change = ch })
      end
      -- Append unreviewed tail questions, skipping any change-Q whose file
      -- the AI already revised (those would just collide on apply).
      for i = 2, #questions do
        local q = questions[i]
        if q.type == "change" and q.change.file and seen_files[q.change.file] then
          -- skip duplicate
        else
          table.insert(new_q, q)
        end
      end
      if #new_q > 0 then
        questions = new_q
        total = #new_q
      end
      -- Always capture the AI's message so render_q can display it inline
      -- above the current question (instead of a fleeting notification).
      if response.message and response.message ~= vim.NIL and response.message ~= "" then
        last_message = response.message
      else
        last_message = nil
      end
      if #questions == 0 then
        if last_message then
          questions = { { type = "message" } }
          total = 1
          render_q()
        else
          close()
        end
      else
        render_q()
      end
    end))
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function() vim.bo[buf].modified = false; send() end,
  })

  local function smart_insert()
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local marker_row = nil
    for i = #all, 1, -1 do
      if all[i] == MARKER then marker_row = i; break end
    end
    if not marker_row then vim.cmd("startinsert"); return end
    local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
    if cursor_row > marker_row then
      vim.cmd("startinsert")
    else
      vim.api.nvim_win_set_cursor(win, { #all, 0 })
      vim.cmd("startinsert!")
    end
  end

  local kopts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q",     close,        kopts)
  vim.keymap.set("n", "<Esc>", close,        kopts)
  vim.keymap.set("n", "<CR>",  confirm,      kopts)
  vim.keymap.set("n", "s",     skip,         kopts)
  vim.keymap.set("n", "i",     smart_insert, kopts)
  vim.keymap.set("n", "a",     smart_insert, kopts)
  vim.keymap.set("n", "A",     smart_insert, kopts)
  vim.keymap.set("n", "I",     smart_insert, kopts)
  vim.keymap.set("n", "o",     smart_insert, kopts)
  vim.keymap.set("n", "O",     smart_insert, kopts)

  -- During streaming, render partial code raw (no MARKER, no reply area).
  -- Once finalize() runs, the question queue takes over and push() becomes a no-op.
  local function push(partial)
    if done or finalized or not vim.api.nvim_buf_is_valid(buf) then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(partial, "\n", { plain = true }))
  end

  -- Called when initial AI call completes. Builds the question queue and
  -- renders question 1.
  local function finalize(response, usage)
    if done or finalized then return end
    stop_gen_spinner()
    finalized = true
    sending_enabled = true
    if usage and usage.session_id then
      session_id = usage.session_id
      if opts.on_session_update then opts.on_session_update(session_id) end
    end

    questions = {}
    if pending.bufnr and response.code and response.code ~= vim.NIL and response.code ~= "" then
      local new_code = vim.trim(response.code)
      -- Suppress code question when AI echoes back identical content with only
      -- whitespace/indentation differences (e.g. answering a question, not editing).
      local orig_lines = vim.api.nvim_buf_is_valid(pending.bufnr)
        and vim.api.nvim_buf_get_lines(pending.bufnr, pending.start_line - 1, pending.end_line, false)
        or {}
      local function norm(s)
        local t = {}
        for l in (s .. "\n"):gmatch("([^\n]*)\n") do
          local trimmed = vim.trim(l)
          if trimmed ~= "" then table.insert(t, trimmed) end
        end
        return table.concat(t, "\n")
      end
      if norm(new_code) ~= norm(table.concat(orig_lines, "\n")) then
        table.insert(questions, { type = "code", code = new_code })
      end
    end
    for _, ch in ipairs(normalize_changes(response.changes)) do
      table.insert(questions, { type = "change", change = ch })
    end
    total = #questions

    if response.message and response.message ~= vim.NIL and response.message ~= "" then
      last_message = response.message
    end

    if #questions == 0 then
      if last_message then
        table.insert(questions, { type = "message" })
        total = 1
        set_pending_indicator()
        render_q()
        return
      else
        vim.notify("novibe: AI returned nothing to apply — closing", vim.log.levels.WARN)
        close()
        return
      end
    end

    local code_count, change_count = 0, 0
    for _, q in ipairs(questions) do
      if q.type == "code" then code_count = code_count + 1
      else change_count = change_count + 1 end
    end
    local parts = {}
    if code_count > 0   then table.insert(parts, code_count .. " in-scope") end
    if change_count > 0 then table.insert(parts, change_count .. " out-of-scope") end
    vim.notify(string.format(
      "novibe: %d question(s) — %s. <CR> apply · s skip · :w revise · q quit.",
      total, table.concat(parts, " + ")
    ), code_count + change_count > 1 and vim.log.levels.WARN or vim.log.levels.INFO)

    set_pending_indicator()
    render_q()

    -- Move focus to chat window only if user was in normal mode, so <CR>
    -- works immediately. Otherwise just notify (don't yank them out of insert).
    local mode = vim.api.nvim_get_mode().mode
    if mode == "n" and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
    else
      vim.notify("novibe: fill ready — navigate to the preview and press <CR>", vim.log.levels.INFO)
    end
  end

  return { push = push, finalize = finalize, cancel = close }
end

-- Focus the active fill-preview chat window.
-- Called by :NovibeActReviewFocus so the user can jump from the working buffer to the
-- chat without reaching for the mouse or using window-navigation keys.
function M.focus_fill()
  if not (_fill_win and vim.api.nvim_win_is_valid(_fill_win)) then
    vim.notify("novibe: no active fill chat to focus", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_set_current_win(_fill_win)
end

-- exposed for tests
M._normalize_changes = normalize_changes
M._buf_context       = buf_context
M._file_context      = file_context

return M
