local apply = require("novibe.apply")

local M = {}

local MARKER = "── reply ──────────────────────────────────────────────────────────────────────"

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local CONFIRM = {
  ok=1, yes=1, y=1, yep=1, sure=1, apply=1, go=1,
  ["do it"]=1, ["go ahead"]=1, confirm=1, ["looks good"]=1,
  ["lgtm"]=1, ["ship it"]=1,
}

local function is_confirm(text)
  return CONFIRM[vim.trim(text):lower()] ~= nil
end

local function split_width()
  -- 40% of editor width, clamped to a comfortable reading range
  return math.min(math.max(math.floor(vim.o.columns * 0.4), 50), 90)
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

local TITLE_IDLE = "%#Title# novibe %#Normal#  ·  :w send  ·  <CR> apply  ·  q quit"
local TITLE_DONE = "%#DiagnosticOk# ✓ done  %#Normal#·  :w send  ·  <CR> apply  ·  q quit"

function M.open(initial_response, opts)
  local bin        = opts.bin
  local provider   = opts.provider
  local session_id = opts.session_id
  -- store changes so confirmations can apply locally without a round-trip
  local pending_changes = initial_response.changes or {}

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

    local stop = start_spinner()

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
        current_job = nil
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

        if response.changes and #response.changes > 0 then
          pending_changes = response.changes
        end

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

  local kopts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q",     close,   kopts)
  vim.keymap.set("n", "<Esc>", close,   kopts)
  vim.keymap.set("n", "<CR>",  confirm, kopts)
end

return M
