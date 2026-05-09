if vim.g.loaded_novibe then
  return
end
vim.g.loaded_novibe = true

vim.api.nvim_create_user_command("NovibeAct", function(opts)
  require("novibe").fill(opts.line1, opts.line2)
end, { range = true, desc = "novibe: act on selection — fill, ask, or #teach" })

vim.api.nvim_create_user_command("NovibeDistill", function()
  local novibe = require("novibe")
  local config = require("novibe.config")
  local learn  = require("novibe.learn")
  local provider = novibe.active_provider()
  local bin = provider.find_bin()
  if not bin then
    vim.notify("novibe: " .. provider.name .. " binary not found", vim.log.levels.ERROR)
    return
  end
  learn.extract(provider, bin, config.options.active_profile)
end, { desc = "novibe: distill accumulated diffs into learned.md" })

vim.api.nvim_create_user_command("NovibePromote", function()
  local novibe  = require("novibe")
  local config  = require("novibe.config")
  local promote = require("novibe.promote")
  local provider = novibe.active_provider()
  local bin = provider.find_bin()
  if not bin then
    vim.notify("novibe: " .. provider.name .. " binary not found", vim.log.levels.ERROR)
    return
  end
  promote.promote(provider, bin, config.options.active_profile)
end, { desc = "novibe: review learned rules and promote mature ones to convention files" })

vim.api.nvim_create_user_command("NovibeProfile", function()
  local config = require("novibe.config")
  local profiles = config.options.profiles or {}
  if #profiles == 0 then
    vim.notify(
      "novibe: no profiles configured — define them in setup({ profiles = {...} })",
      vim.log.levels.WARN
    )
    return
  end
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
  novibe._skip_continue       = true
  novibe._session_count       = 0
  novibe._opencode_session_id = nil
  vim.notify("novibe: session reset — next fill starts a fresh conversation", vim.log.levels.INFO)
end, { desc = "novibe: reset session (next fill starts fresh)" })

vim.api.nvim_create_user_command("NovibeStatus", function()
  local config  = require("novibe.config")
  local novibe  = require("novibe")
  local no_vibe = require("novibe.no_vibe")

  local lines = {}

  local profile = config.options.active_profile
  if profile then
    local prov = profile.provider or "claude"
    local effort = profile.effort and (", effort=" .. profile.effort) or ""
    table.insert(lines, "Profile:  " .. profile.label
      .. " [" .. prov .. "] (" .. (profile.model or "?") .. effort .. ")")
  else
    table.insert(lines, "Profile:  none (claude CLI defaults)")
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

  local cost = novibe._session_cost or 0
  if cost > 0 then
    table.insert(lines, string.format("Cost:     $%.4f this session", cost))
  end

  local usage = novibe._last_usage
  if usage and usage.input_tokens and usage.context_window and usage.context_window > 0 then
    local pct = math.floor(usage.input_tokens / usage.context_window * 100)
    table.insert(lines, string.format("Context:  %d%% of %dk window (last fill)", pct, math.floor(usage.context_window / 1000)))
  end

  local found = no_vibe.discover()
  if found then
    local names = {}
    if found.novibe_md then table.insert(names, "NO_VIBE.md") end
    for _, f in ipairs(found.conventions) do
      table.insert(names, ".no_vibe/" .. vim.fn.fnamemodify(f, ":t"))
    end
    for _, f in ipairs(found.learned) do
      table.insert(names, ".no_vibe/" .. vim.fn.fnamemodify(f, ":t"))
    end
    table.insert(lines, "Rules:    " .. table.concat(names, ", "))
    table.insert(lines, "Root:     " .. vim.fn.fnamemodify(found.root, ":~"))
  else
    table.insert(lines, "Rules:    none found (walked up from " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":~") .. ")")
  end

  vim.notify("novibe\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end, { desc = "novibe: show active profile, session state, and loaded rule files" })

vim.api.nvim_create_user_command("NovibeConventions", function()
  local no_vibe = require("novibe.no_vibe")
  local found   = no_vibe.discover()

  if not found or (not found.novibe_md and #found.conventions == 0) then
    vim.notify(
      "novibe: no convention files found (walked up from " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":~") .. ")",
      vim.log.levels.WARN
    )
    return
  end

  local files = {}
  if found.novibe_md then table.insert(files, found.novibe_md) end
  for _, f in ipairs(found.conventions) do table.insert(files, f) end

  vim.ui.select(files, {
    prompt = "novibe: open convention file",
    format_item = function(f) return vim.fn.fnamemodify(f, ":~:.") end,
  }, function(choice)
    if choice then vim.cmd("edit " .. vim.fn.fnameescape(choice)) end
  end)
end, { desc = "novibe: browse and open canonical convention files" })

vim.api.nvim_create_user_command("NovibeLearns", function()
  local no_vibe = require("novibe.no_vibe")
  local found   = no_vibe.discover()

  if not found or #found.learned == 0 then
    vim.notify(
      "novibe: no learned-*.md files yet — run :NovibeAct with #teach to start staging rules",
      vim.log.levels.WARN
    )
    return
  end

  vim.ui.select(found.learned, {
    prompt = "novibe: open learned (staged) file",
    format_item = function(f) return vim.fn.fnamemodify(f, ":~:.") end,
  }, function(choice)
    if choice then vim.cmd("edit " .. vim.fn.fnameescape(choice)) end
  end)
end, { desc = "novibe: browse and open staged learned-*.md files" })
