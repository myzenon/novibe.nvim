if vim.g.loaded_novibe then
  return
end
vim.g.loaded_novibe = true

vim.api.nvim_create_user_command("NovibeConsult", function(opts)
  require("novibe.consult").open(opts.line1, opts.line2, opts.range > 0)
end, { range = true, desc = "novibe: open interactive consult session with current file/selection context" })

vim.api.nvim_create_user_command("NovibeAgent", function(opts)
  require("novibe.consult").open_agent(opts.line1, opts.line2, opts.range > 0)
end, { range = true, desc = "novibe: open agent session — plan then execute with full project access" })

vim.api.nvim_create_user_command("NovibeConsultPrompt", function(opts)
  require("novibe.consult").send_prompt(opts.line1, opts.line2, opts.range > 0)
end, { range = true, desc = "novibe: send current file/selection context to active consult terminal (for opencode)" })

vim.api.nvim_create_user_command("NovibeAgentPrompt", function(opts)
  require("novibe.consult").send_agent_prompt(opts.line1, opts.line2, opts.range > 0)
end, { range = true, desc = "novibe: re-inject no_vibe conventions + context into active agent session" })

vim.api.nvim_create_user_command("NovibeAct", function(opts)
  require("novibe").fill(opts.line1, opts.line2)
end, { range = true, desc = "novibe: act on selection — fill, ask, or #teach" })

vim.api.nvim_create_user_command("NovibeAct2", function(opts)
  require("novibe.act2").fill(opts.line1, opts.line2)
end, { range = true, desc = "novibe: act2 — fill in-place with virt_line review controls, no chat window" })

vim.api.nvim_create_user_command("NovibeGen", function(opts)
  require("novibe.gen").open(opts.line1, opts.line2, opts.range > 0)
end, { range = true, desc = "novibe: generate new files — prompt if empty, list if pending" })

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
  local slots = {
    { key = "active_profile",         label = "Act",     prompt = "Act profile" },
    { key = "active_consult_profile", label = "Consult", prompt = "Consult profile" },
  }
  vim.ui.select(slots, {
    prompt = "Novibe: configure profile for…",
    format_item = function(s)
      local cur = config.options[s.key]
      return s.label .. (cur and ("  [" .. cur.label .. "]") or "  [none]")
    end,
  }, function(slot)
    if not slot then return end
    vim.ui.select(profiles, {
      prompt = "Novibe: " .. slot.prompt,
      format_item = function(p)
        local cur = config.options[slot.key]
        local prov = p.provider or "claude"
        local detail = "[" .. prov .. "]"
        if p.model then detail = detail .. "  " .. p.model end
        if p.effort then detail = detail .. "  effort=" .. p.effort end
        local active = cur and cur.label == p.label and "  ✓" or ""
        return p.label .. "  " .. detail .. active
      end,
    }, function(choice)
      if choice then
        config.options[slot.key] = choice
        config.save_state()
        vim.notify("novibe: " .. slot.label .. " profile → " .. choice.label, vim.log.levels.INFO)
      end
    end)
  end)
end, { desc = "novibe: pick profile for Act or Consult" })

vim.api.nvim_create_user_command("NovibeActReviewFocus", function()
  require("novibe.chat").focus_fill()
end, { desc = "novibe: focus the active fill-preview chat window" })

vim.api.nvim_create_user_command("NovibeReset", function()
  local novibe = require("novibe")
  novibe._skip_continue       = true
  novibe._session_count       = 0
  novibe._session_id = nil
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
    table.insert(lines, "Session:  " .. count .. " fill(s) in current session")
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

vim.api.nvim_create_user_command("NovibeKB", function()
  local no_vibe = require("novibe.no_vibe")
  local found   = no_vibe.discover()

  if not found then
    vim.notify(
      "novibe: no .no_vibe files found (walked up from " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":~") .. ")",
      vim.log.levels.WARN
    )
    return
  end

  local categories = {}
  local function add(label, files)
    if files and #files > 0 then
      table.insert(categories, { label = label, files = files })
    end
  end

  if found.novibe_md then
    table.insert(categories, { label = "NO_VIBE.md", files = { found.novibe_md } })
  end
  add("Convention", found.conventions)
  add("Learn",      found.learned)
  add("Map",        found.maps)
  add("Rule",       found.rules)
  add("Decision",   found.decisions)

  if #categories == 0 then
    vim.notify("novibe: no .no_vibe files found", vim.log.levels.WARN)
    return
  end

  local function open_file(f)
    vim.cmd("edit " .. vim.fn.fnameescape(f))
  end

  local function pick_file(cat)
    if #cat.files == 1 then open_file(cat.files[1]); return end
    vim.ui.select(cat.files, {
      prompt = "novibe KB › " .. cat.label,
      format_item = function(f) return vim.fn.fnamemodify(f, ":t") end,
    }, function(choice)
      if choice then open_file(choice) end
    end)
  end

  vim.ui.select(categories, {
    prompt = "novibe KB",
    format_item = function(c) return c.label .. "  (" .. #c.files .. ")" end,
  }, function(cat)
    if cat then pick_file(cat) end
  end)
end, { desc = "novibe: browse all .no_vibe knowledge base files by category" })
