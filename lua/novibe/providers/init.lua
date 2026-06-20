local M = {}

local providers = {
  claude       = require("novibe.providers.claude"),
  opencode     = require("novibe.providers.opencode"),
  codex        = require("novibe.providers.codex"),
  antigravity  = require("novibe.providers.antigravity"),
}

function M.get(name)
  return providers[name or "claude"] or providers.claude
end

return M
