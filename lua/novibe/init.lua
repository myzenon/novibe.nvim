local M = {}
local config    = require("novibe.config")
local input     = require("novibe.input")
local chat      = require("novibe.chat")
local apply     = require("novibe.apply")
local glob      = require("novibe.glob")
local no_vibe   = require("novibe.no_vibe")
local learn     = require("novibe.learn")
local providers = require("novibe.providers")

M._last_fill            = nil    -- { original, bufnr, start_line }
M._session_count        = 0      -- fills since last reset
M._skip_continue        = false  -- set true by :NovibeReset; consumed on next fill
M._session_cost         = 0.0    -- cumulative USD this Neovim session
M._last_usage           = nil    -- usage table from most recent fill
M._opencode_session_id  = nil    -- captured from opencode response, reused for next fill

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


function M.active_provider()
  local profile = config.options.active_profile
  return providers.get(profile and profile.provider)
end

-- Walk parent dirs from the buffer's file looking for a project root marker.
-- Falls back to cwd if none found.
local function project_root(file)
  if not file or file == "" then return vim.fn.getcwd() end
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

-- Sibling files in the same directory + paths resolved from `import ... from "..."`
-- and `require("...")` lines in the buffer. Used only when profile.file_context is true.
local function gather_file_context(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then return nil end
  local dir = vim.fn.fnamemodify(file, ":h")
  local root = project_root(file)

  local function rel(p) return (vim.fn.fnamemodify(p, ":."):gsub("^" .. vim.pesc(root) .. "/", "")) end

  local seen, list = {}, {}
  local function add(p)
    if not p or seen[p] then return end
    if vim.fn.filereadable(p) == 0 then return end
    seen[p] = true
    table.insert(list, rel(p))
  end

  -- siblings
  for _, p in ipairs(vim.fn.glob(dir .. "/*", false, true)) do
    if vim.fn.isdirectory(p) == 0 then add(p) end
  end

  -- relative imports in this buffer
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local exts = { "", ".ts", ".tsx", ".js", ".jsx", ".lua", ".py", ".go", "/index.ts", "/index.tsx", "/index.js" }
  for _, line in ipairs(lines) do
    local imp = line:match("from%s+['\"]([^'\"]+)['\"]")
              or line:match("require%s*%(?%s*['\"]([^'\"]+)['\"]")
    if imp and (imp:sub(1, 2) == "./" or imp:sub(1, 3) == "../") then
      local base = vim.fn.simplify(dir .. "/" .. imp)
      for _, ext in ipairs(exts) do
        if vim.fn.filereadable(base .. ext) == 1 then add(base .. ext); break end
      end
    end
  end

  if #list == 0 then return nil end
  table.sort(list)
  return list
end


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
  local provider = M.active_provider()
  local bin = provider.find_bin()
  if not bin then
    vim.notify("novibe: " .. provider.name .. " binary not found", vim.log.levels.ERROR)
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

    -- #teach mode: accumulate evidence for distillation.
    -- If a recent fill exists in this buffer, captures the diff (AI vs user).
    -- Otherwise records the current selection as a direct rule note.
    if vim.startswith(user_prompt, "#teach") then
      local reason  = vim.trim(user_prompt:sub(7))
      local current = table.concat(
        vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false), "\n"
      )
      local original = nil
      if M._last_fill and M._last_fill.bufnr == bufnr then
        original = M._last_fill.original
      end
      learn.teach(
        original,
        current,
        reason,
        vim.api.nvim_buf_get_name(bufnr),
        provider,
        bin,
        config.options.learn and config.options.learn.auto_extract_after,
        config.options.active_profile
      )
      return
    end

    local filename    = vim.api.nvim_buf_get_name(bufnr)
    local no_vibe_txt = no_vibe.load(filename)
    local active_profile = config.options.active_profile
    local parts = {
      config.options.system_prompt,
      no_vibe_txt and ("\nProject conventions:\n" .. no_vibe_txt) or "",
      "",
    }

    if active_profile and active_profile.file_context then
      local files = gather_file_context(bufnr)
      if files then
        local rel_current = vim.fn.fnamemodify(filename, ":.")
        table.insert(parts, "Project files (only reference these paths in changes[]; do NOT invent paths):")
        for _, f in ipairs(files) do
          local marker = (f == rel_current) and "  (current)" or ""
          table.insert(parts, "  " .. f .. marker)
        end
        table.insert(parts, "")
      end
    end

    local ctx_before_top = math.max(1, start_line - 10)
    local enclosing = require("novibe.context").enclosing(bufnr, start_line, ctx_before_top)
    if enclosing then
      table.insert(parts, enclosing)
      table.insert(parts, "")
    end
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
    if diag_txt then
      table.insert(parts, "")
      table.insert(parts, diag_txt)
    end

    if user_prompt ~= "" then
      table.insert(parts, "")
      table.insert(parts, "Instruction: " .. user_prompt)
    end
    local prompt = table.concat(parts, "\n")

    -- open fill chat immediately — no focus steal, streaming goes here
    local fill_chat = chat.open_fill(
      { bufnr = bufnr, start_line = start_line, end_line = end_line,
        on_apply = function(code)
          M._last_fill = { original = vim.trim(code), bufnr = bufnr, start_line = start_line }
        end },
      { bin = bin, provider = provider, session_id = M._opencode_session_id,
        on_session_update = function(sid) M._opencode_session_id = sid end }
    )

    local stop_spinner = start_spinner(bufnr, start_line, end_line)

    local profile = config.options.active_profile
    local carry = not M._skip_continue
    M._skip_continue = false

    local cmd = provider.build_cmd(bin, prompt, {
      profile      = profile,
      bare         = config.options.bare,
      use_continue = carry,
      session_id   = carry and M._opencode_session_id or nil,
      stream       = provider.streaming,
    })

    local sctx = { raw = "", text = "" }

    local sys_opts = { text = true }
    if provider.streaming then
      sys_opts.stdout = function(_, data)
        if not data then return end
        sctx.raw  = sctx.raw  .. data
        local chunk_text = provider.parse_chunk(data)
        if chunk_text == "" then return end
        sctx.text = sctx.text .. chunk_text
        local partial = require("novibe.stream").extract_code(sctx.text)
        if partial then
          vim.schedule(function() fill_chat.push(partial) end)
        end
      end
    end

    vim.system(
      cmd,
      sys_opts,
      vim.schedule_wrap(function(result)
        stop_spinner()

        local stdout = provider.streaming and sctx.raw or (result.stdout or "")

        if result.code ~= 0 or stdout == "" then
          vim.notify(
            string.format("novibe: exit %d — %s", result.code, vim.trim(result.stderr or "")),
            vim.log.levels.ERROR
          )
          fill_chat.cancel()
          return
        end

        local response, usage = provider.parse_output(stdout)

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

        fill_chat.finalize(response, usage)
      end)
    )
  end, { stats = input_stats, profile = config.options.active_profile })
end

return M
