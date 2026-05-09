if vim.g.loaded_novibe then
  return
end
vim.g.loaded_novibe = true

vim.api.nvim_create_user_command("NovibeAct", function(opts)
  require("novibe").fill(opts.line1, opts.line2)
end, { range = true, desc = "novibe: act on selection — fill, ask, or #teach" })

vim.api.nvim_create_user_command("NovibeDistill", function()
  local novibe = require("novibe")
  local config  = require("novibe.config")
  local learn   = require("novibe.learn")
  local claude_bin = novibe._find_claude and novibe._find_claude()
  if not claude_bin then
    vim.notify("novibe: claude binary not found", vim.log.levels.ERROR)
    return
  end
  learn.extract(claude_bin, config.options.active_profile)
end, { desc = "novibe: distill accumulated diffs into learned.md" })

vim.api.nvim_create_user_command("NovibeProfile", function()
  local config = require("novibe.config")
  local profiles = config.options.profiles or {}
  vim.ui.select(profiles, {
    prompt = "Novibe: profile",
    format_item = function(p)
      local active = config.options.active_profile
      local current = active and active.label == p.label
      return p.label .. (current and "  ✓" or "")
    end,
  }, function(choice)
    if choice then
      config.options.active_profile = choice
      vim.notify("novibe: profile → " .. choice.label, vim.log.levels.INFO)
    end
  end)
end, { desc = "novibe: pick profile (model + effort)" })

vim.api.nvim_create_user_command("NovibeReset", function()
  local novibe = require("novibe")
  novibe._skip_continue = true
  novibe._session_count = 0
  vim.notify("novibe: session reset — next fill starts a fresh conversation", vim.log.levels.INFO)
end, { desc = "novibe: reset claude session (next fill starts fresh)" })

vim.api.nvim_create_user_command("NovibeStatus", function()
  local config  = require("novibe.config")
  local novibe  = require("novibe")
  local cwd     = vim.fn.getcwd()

  local lines = {}

  local profile = config.options.active_profile
  if profile then
    table.insert(lines, "Profile:  " .. profile.label
      .. " (" .. profile.model .. ", effort=" .. profile.effort .. ")")
  else
    table.insert(lines, "Profile:  none (CLI defaults)")
  end

  table.insert(lines, "Bare:     " .. (config.options.bare and "on" or "off"))

  local count   = novibe._session_count or 0
  local pending = novibe._skip_continue
  if pending then
    table.insert(lines, "Session:  pending reset (next fill starts fresh)")
  elseif count == 0 then
    table.insert(lines, "Session:  fresh (no fills yet)")
  else
    table.insert(lines, "Session:  " .. count .. " fill(s) with --continue")
  end

  local found = {}
  if vim.fn.filereadable(cwd .. "/NO_VIBE.md") == 1 then
    table.insert(found, "NO_VIBE.md")
  end
  local conv = vim.fn.glob(cwd .. "/.no_vibe/convention-*.md", false, true)
  table.sort(conv)
  for _, f in ipairs(conv) do table.insert(found, ".no_vibe/" .. vim.fn.fnamemodify(f, ":t")) end
  local learned = vim.fn.glob(cwd .. "/.no_vibe/learned-*.md", false, true)
  table.sort(learned)
  for _, f in ipairs(learned) do table.insert(found, ".no_vibe/" .. vim.fn.fnamemodify(f, ":t")) end

  if #found > 0 then
    table.insert(lines, "Rules:    " .. table.concat(found, ", "))
  else
    table.insert(lines, "Rules:    none found in " .. vim.fn.fnamemodify(cwd, ":~"))
  end

  vim.notify("novibe\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end, { desc = "novibe: show active profile, session state, and loaded rule files" })

vim.api.nvim_create_user_command("NovibeConventions", function()
  local cwd   = vim.fn.getcwd()
  local files = {}

  local nv = cwd .. "/NO_VIBE.md"
  if vim.fn.filereadable(nv) == 1 then table.insert(files, nv) end

  local conv = vim.fn.glob(cwd .. "/.no_vibe/convention-*.md", false, true)
  table.sort(conv)
  for _, f in ipairs(conv) do table.insert(files, f) end

  local learned = vim.fn.glob(cwd .. "/.no_vibe/learned-*.md", false, true)
  table.sort(learned)
  for _, f in ipairs(learned) do table.insert(files, f) end

  if #files == 0 then
    vim.notify("novibe: no convention files found in " .. vim.fn.fnamemodify(cwd, ":~"), vim.log.levels.WARN)
    return
  end

  vim.ui.select(files, {
    prompt = "novibe: open convention file",
    format_item = function(f) return vim.fn.fnamemodify(f, ":~:.") end,
  }, function(choice)
    if choice then vim.cmd("edit " .. vim.fn.fnameescape(choice)) end
  end)
end, { desc = "novibe: browse and open convention/learned files" })
