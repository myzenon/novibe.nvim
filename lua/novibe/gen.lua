local M = {}

local config    = require("novibe.config")
local input     = require("novibe.input")
local no_vibe   = require("novibe.no_vibe")
local providers = require("novibe.providers")

-- At most one pending batch at a time.
-- Each entry: { path, content, prompt, bufnr }
local _pending = {}

-- ─── helpers ──────────────────────────────────────────────────────────────────

local function project_root()
  local file = vim.fn.expand("%:p")
  if file == "" then return vim.fn.getcwd() end
  local dir = vim.fn.fnamemodify(file, ":p:h")
  for _ = 1, 10 do
    for _, marker in ipairs({ ".git", "package.json", "Cargo.toml", "pyproject.toml", "go.mod" }) do
      if vim.fn.filereadable(dir .. "/" .. marker) == 1
         or vim.fn.isdirectory(dir .. "/" .. marker) == 1 then
        return dir
      end
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return vim.fn.getcwd()
end

local function remove_entry(bufnr)
  for i, e in ipairs(_pending) do
    if e.bufnr == bufnr then
      table.remove(_pending, i)
      return
    end
  end
end

local function set_winbar(buf, path)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.wo[win].winbar = "  novibe  " .. path
      .. "  ·  <C-f> change path"
      .. "  ·  <leader>r re-prompt"
      .. "  ·  :w save"
  end
end

-- ─── gen buffer ───────────────────────────────────────────────────────────────

local function do_reprompt(buf, entry)
  local profile  = config.options.active_profile
  local provider = providers.get(profile and profile.provider)
  local bin      = provider.find_bin()
  if not bin then
    vim.notify("novibe gen: " .. provider.name .. " binary not found", vim.log.levels.ERROR)
    return
  end

  input.open(function(new_prompt)
    if not new_prompt or new_prompt == "" then return end
    entry.prompt = new_prompt

    -- show placeholder while waiting
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- generating…" })
    end

    local root        = project_root()
    local no_vibe_txt = no_vibe.load("")
    local novibe      = require("novibe")
    local ctx         = entry.ctx or {}
    local prompt      = novibe._build_gen_prompt(
      new_prompt, root, no_vibe_txt,
      ctx.buf_name or "", ctx.selection or "")
    if ctx.diag_txt and ctx.diag_txt ~= "" then
      prompt = prompt .. "\n" .. ctx.diag_txt
    end

    local cmd = provider.build_cmd(bin, prompt, {
      profile      = profile,
      bare         = config.options.bare,
      use_continue = false,
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
      if not vim.api.nvim_buf_is_valid(buf) then return end
      local stdout = provider.streaming and sctx.raw or (result.stdout or "")
      if result.code ~= 0 or stdout == "" then
        vim.notify(
          string.format("novibe gen: exit %d — %s", result.code, vim.trim(result.stderr or "")),
          vim.log.levels.ERROR
        )
        return
      end

      local response = provider.parse_output(stdout)
      if type(response.changes) ~= "table" then return end

      for _, ch in ipairs(response.changes) do
        if ch.action == "create" and ch.replace and ch.replace ~= "" then
          entry.content = ch.replace
          if ch.file and ch.file ~= "" and ch.file ~= entry.path then
            entry.path = ch.file
            pcall(vim.api.nvim_buf_set_name, buf, ch.file)
          end
          vim.api.nvim_buf_set_lines(buf, 0, -1, false,
            vim.split(ch.replace, "\n", { plain = true }))
          set_winbar(buf, entry.path)
          break
        end
      end
    end))
  end, { profile = profile, initial = entry.prompt })
end

local function open_gen_buf(entry)
  local buf = vim.api.nvim_create_buf(true, false)  -- listed, not scratch
  entry.bufnr = buf

  -- name the buffer so :w saves to the proposed path
  pcall(vim.api.nvim_buf_set_name, buf, entry.path)

  local lines = vim.split(entry.content, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local ft = vim.filetype.match({ filename = entry.path }) or ""
  if ft ~= "" then
    vim.bo[buf].filetype = ft
    local lang = (vim.treesitter.language.get_lang and vim.treesitter.language.get_lang(ft)) or ft
    pcall(vim.treesitter.start, buf, lang)
  end

  vim.api.nvim_set_current_buf(buf)
  set_winbar(buf, entry.path)

  local bopts = { buffer = buf, nowait = true }

  -- <C-f>: edit the save path via a small input float pre-filled with current path
  vim.keymap.set("n", "<C-f>", function()
    input.open(function(new_path)
      if not new_path or new_path == "" then return end
      entry.path = new_path
      pcall(vim.api.nvim_buf_set_name, buf, new_path)
      local new_ft = vim.filetype.match({ filename = new_path }) or ""
      if new_ft ~= "" and new_ft ~= vim.bo[buf].filetype then
        vim.bo[buf].filetype = new_ft
      end
      set_winbar(buf, new_path)
    end, { initial = entry.path })
  end, bopts)

  -- <leader>r: re-prompt with the same or new description
  vim.keymap.set("n", "<leader>r", function()
    do_reprompt(buf, entry)
  end, bopts)

  -- remove from pending when saved or abandoned
  local ag = vim.api.nvim_create_augroup("novibe_gen_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = buf, group = ag, once = true,
    callback = function() remove_entry(buf) end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf, group = ag, once = true,
    callback = function()
      remove_entry(buf)
      pcall(vim.api.nvim_del_augroup_by_id, ag)
    end,
  })
end

-- ─── list picker ──────────────────────────────────────────────────────────────

local function open_list()
  vim.ui.select(_pending, {
    prompt = "novibe gen — pending files (save or wipe to clear)",
    format_item = function(e)
      local tag = (e.bufnr and vim.api.nvim_buf_is_valid(e.bufnr)) and "  [open]" or ""
      return e.path .. tag
    end,
  }, function(entry)
    if not entry then return end
    if entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) then
      local wins = vim.fn.win_findbuf(entry.bufnr)
      if #wins > 0 then
        vim.api.nvim_set_current_win(wins[1])
      else
        vim.api.nvim_set_current_buf(entry.bufnr)
      end
    else
      open_gen_buf(entry)
    end
  end)
end

-- ─── prompt assembly ──────────────────────────────────────────────────────────

-- Exposed for testing.
function M._build_prompt(description, ctx, root, no_vibe_txt)
  ctx = ctx or {}
  local novibe = require("novibe")
  local prompt = novibe._build_gen_prompt(
    description, root or "", no_vibe_txt,
    ctx.buf_name or "", ctx.selection or "")
  if ctx.diag_txt and ctx.diag_txt ~= "" then
    prompt = prompt .. "\n" .. ctx.diag_txt
  end
  return prompt
end

-- ─── generation ───────────────────────────────────────────────────────────────

-- ctx: { buf_name, selection, diag_txt } — all optional
local function run_gen(description, ctx)
  ctx = ctx or {}
  local profile  = config.options.active_profile
  local provider = providers.get(profile and profile.provider)
  local bin      = provider.find_bin()
  if not bin then
    vim.notify("novibe: " .. provider.name .. " binary not found", vim.log.levels.ERROR)
    return
  end

  local root        = project_root()
  local no_vibe_txt = no_vibe.load("")
  local prompt      = M._build_prompt(description, ctx, root, no_vibe_txt)

  vim.notify("novibe gen: generating…", vim.log.levels.INFO)

  local cmd = provider.build_cmd(bin, prompt, {
    profile      = profile,
    bare         = config.options.bare,
    use_continue = false,
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
    local stdout = provider.streaming and sctx.raw or (result.stdout or "")
    if result.code ~= 0 or stdout == "" then
      vim.notify(
        string.format("novibe gen: exit %d — %s", result.code, vim.trim(result.stderr or "")),
        vim.log.levels.ERROR
      )
      return
    end

    local response = provider.parse_output(stdout)
    if type(response.changes) ~= "table" or #response.changes == 0 then
      vim.notify("novibe gen: no files proposed", vim.log.levels.WARN)
      return
    end

    _pending = {}
    for _, ch in ipairs(response.changes) do
      if ch.action == "create" and ch.file and ch.replace then
        table.insert(_pending, {
          path    = ch.file,
          content = ch.replace,
          prompt  = description,
          ctx     = ctx,
          bufnr   = nil,
        })
      end
    end

    if #_pending == 0 then
      vim.notify("novibe gen: no create actions in response", vim.log.levels.WARN)
      return
    end

    if #_pending == 1 then
      open_gen_buf(_pending[1])
    else
      open_list()
    end
  end))
end

-- ─── entry point ──────────────────────────────────────────────────────────────

-- line1, line2: from command range (1-indexed); has_range: range > 0
function M.open(line1, line2, has_range)
  if #_pending > 0 then
    open_list()
    return
  end

  local bufnr    = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)
  local buf_name = vim.fn.fnamemodify(filename, ":.")

  -- capture visual selection or current line as reference context
  local sl = (has_range and line1) or vim.api.nvim_win_get_cursor(0)[1]
  local el = (has_range and line2) or sl
  local sel_lines = vim.api.nvim_buf_get_lines(bufnr, sl - 1, el, false)
  local selection = table.concat(sel_lines, "\n")

  local diag_txt = require("novibe.diag").format(bufnr, sl, el)

  local ctx = { buf_name = buf_name, selection = selection, diag_txt = diag_txt }

  input.open(function(description)
    if not description or description == "" then return end
    run_gen(description, ctx)
  end)
end

return M
