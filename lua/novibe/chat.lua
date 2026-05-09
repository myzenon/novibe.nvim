local apply = require("novibe.apply")

local M = {}

local WIDTH  = 82
local HEIGHT = 26
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

local function center_cfg(h)
  local ui = vim.api.nvim_list_uis()[1]
  local sh = ui and ui.height or 40
  local sw = ui and ui.width  or 120
  return {
    relative  = "editor",
    row       = math.floor((sh - h - 2) / 2),
    col       = math.floor((sw - WIDTH - 2) / 2),
    width     = WIDTH,
    height    = h,
    style     = "minimal",
    border    = "rounded",
    title     = " novibe: follow-up ",
    title_pos = "center",
    footer    = " :w send  ·  q quit ",
    footer_pos = "center",
  }
end

-- Build lines + highlight specs [{line (0-based), hl}] for the read-only section
local function render(response)
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

  for _, change in ipairs(response.changes or {}) do
    push("┌─ " .. change.file .. "  [" .. (change.action or "replace") .. "]", "Title")
    push("│  " .. change.description, "Comment")
    push("│")
    for _, l in ipairs(vim.split(vim.trim(change.find), "\n", { plain = true })) do
      push("  - " .. l, "DiffDelete")
    end
    for _, l in ipairs(vim.split(vim.trim(change.replace), "\n", { plain = true })) do
      push("  + " .. l, "DiffAdd")
    end
    push("└" .. string.rep("─", WIDTH - 2), "Comment")
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

local function schema_reminder()
  return '\n\n[Respond ONLY in JSON: {"message":...,"changes":[...],"done":true/false}]'
end

function M.open(initial_response, claude_bin)
  -- store changes so confirmations can apply locally without a round-trip
  local pending_changes = initial_response.changes or {}

  local ns  = vim.api.nvim_create_namespace("novibe_chat")
  local buf = vim.api.nvim_create_buf(false, true)
  -- unique name per instance avoids "buffer name already in use" if a prior
  -- chat buffer hasn't been wiped yet (rapid double-invocation)
  pcall(vim.api.nvim_buf_set_name, buf, "novibe://chat/" .. vim.uv.hrtime())
  vim.bo[buf].buftype   = "acwrite"
  vim.bo[buf].bufhidden = "wipe"

  local response_lines, hls = render(initial_response)
  local init_h = math.min(math.max(#response_lines + 6, 12), 30)
  local win = vim.api.nvim_open_win(buf, true, center_cfg(init_h))
  vim.wo[win].wrap      = true
  vim.wo[win].linebreak = true

  local done = false

  local function set_content(r_lines, r_hls)
    local content = vim.list_extend(vim.deepcopy(r_lines), { MARKER, "" })
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    apply_hls(ns, buf, r_hls)

    -- focus the chat window before startinsert; otherwise insert mode would
    -- activate in whatever window the user clicked over to during the spinner
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { #content, 0 })
      vim.cmd("startinsert")
    end
  end

  set_content(response_lines, hls)

  local function close()
    done = true
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function extract_reply()
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- find marker scanning from bottom
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
      vim.api.nvim_win_set_config(win, {
        footer = " " .. spinner_frames[frame] .. " thinking…  ·  q quit ",
        footer_pos = "center",
      })
    end))
    return function()
      timer:stop(); timer:close()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_config(win, { footer = " :w send  ·  q quit ", footer_pos = "center" })
      end
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

    local msg = reply ~= "" and (reply .. schema_reminder()) or ("continue" .. schema_reminder())

    vim.system(
      { claude_bin, "--continue", "--print", msg },
      { text = true },
      vim.schedule_wrap(function(result)
        stop()
        if not vim.api.nvim_win_is_valid(win) then return end

        if result.code ~= 0 or (result.stdout or "") == "" then
          vim.notify(
            string.format("novibe: exit %d — %s", result.code, vim.trim(result.stderr or "")),
            vim.log.levels.ERROR
          )
          return
        end

        local raw = vim.trim(result.stdout)
        local ok, response = pcall(vim.json.decode, raw)
        if not ok then
          response = { message = raw, changes = {}, done = false }
        end

        -- keep pending_changes up to date for local confirm ("ok/yes")
        if response.changes and #response.changes > 0 then
          pending_changes = response.changes
        end

        if response.done then
          -- only apply what Claude explicitly returned in this turn
          -- never apply stale pending_changes from a previous proposal
          if response.changes and #response.changes > 0 then
            apply.apply_all(response.changes)
          end
          close()
          return
        end

        local new_lines, new_hls = render(response)
        set_content(new_lines, new_hls)
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

  local opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q",     close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
end

return M
