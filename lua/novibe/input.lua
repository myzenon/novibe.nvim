local M = {}

local WIDTH = 52
local HEIGHT = 4

function M.open(on_submit, opts)
  opts = opts or {}
  local ui = vim.api.nvim_list_uis()[1]
  local screen_h = ui and ui.height or 40
  local screen_w = ui and ui.width or 120

  local row = math.floor((screen_h - HEIGHT - 2) / 2)
  local col = math.floor((screen_w - WIDTH - 2) / 2)

  local title_parts = {}
  if opts.profile then
    local p = opts.profile
    if p.provider then table.insert(title_parts, p.provider) end
    if p.model    then table.insert(title_parts, p.model:match("[^/]+$") or p.model) end
    if p.effort   then table.insert(title_parts, p.effort) end
  else
    table.insert(title_parts, "claude · default")
  end
  if opts.stats then table.insert(title_parts, opts.stats) end
  local title = " novibe  " .. table.concat(title_parts, " · ") .. " "

  local input_buf = vim.api.nvim_create_buf(false, true)
  -- unique name avoids collision if a prior input buffer hasn't been wiped yet
  pcall(vim.api.nvim_buf_set_name, input_buf, "novibe://input/" .. vim.uv.hrtime())
  vim.bo[input_buf].buftype = "acwrite"
  vim.bo[input_buf].bufhidden = "wipe"
  vim.bo[input_buf].filetype = "markdown"

  if opts.initial and opts.initial ~= "" then
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false,
      vim.split(opts.initial, "\n", { plain = true }))
  end

  local win = vim.api.nvim_open_win(input_buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = WIDTH,
    height = HEIGHT,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    footer = " :w submit  ·  q cancel  ·  <C-f> files ",
    footer_pos = "center",
  })

  vim.wo[win].wrap = true
  vim.cmd("startinsert")

  local done = false

  local function close()
    done = true
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function submit()
    if done then return end
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    close()
    vim.schedule(function() on_submit(text) end)
  end

  local function cancel()
    if done then return end
    close()
    vim.schedule(function() on_submit(nil) end)
  end

  -- :w submits — must clear modified flag or Neovim refuses to fire BufWriteCmd
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = input_buf,
    callback = function()
      vim.bo[input_buf].modified = false
      submit()
    end,
  })

  local opts = { buffer = input_buf, nowait = true }
  -- <Esc> only in normal mode — insert mode <Esc> stays default (→ normal mode)
  vim.keymap.set("n", "<Esc>", cancel, opts)
  vim.keymap.set("n", "q", cancel, opts)
  -- <C-f> opens snacks file picker; inserts selected path at cursor (handles () and nested dirs)
  vim.keymap.set("i", "<C-f>", function()
    local ok, snacks = pcall(require, "snacks")
    if not ok then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x><C-f>", true, false, true), "n", false)
      return
    end
    snacks.picker.files({
      confirm = function(picker, item)
        picker:close()
        if not item then return end
        local path = item.file or item.path or item.text
        if not path then return end
        vim.schedule(function()
          if not vim.api.nvim_win_is_valid(win) then return end
          vim.api.nvim_set_current_win(win)
          local cursor = vim.api.nvim_win_get_cursor(win)
          local r, c = cursor[1], cursor[2]
          local line = vim.api.nvim_buf_get_lines(input_buf, r - 1, r, false)[1] or ""
          vim.api.nvim_buf_set_lines(input_buf, r - 1, r, false, { line:sub(1, c) .. path .. line:sub(c + 1) })
          vim.api.nvim_win_set_cursor(win, { r, c + #path })
          vim.cmd("startinsert")
        end)
      end,
    })
  end, { buffer = input_buf })
end

return M
