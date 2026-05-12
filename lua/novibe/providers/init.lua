local M = {}

local providers = {
  claude   = require("novibe.providers.claude"),
  opencode = require("novibe.providers.opencode"),
  gemini   = require("novibe.providers.gemini"),
}

function M.get(name)
  return providers[name or "claude"] or providers.claude
end

return M
