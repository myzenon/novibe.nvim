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
