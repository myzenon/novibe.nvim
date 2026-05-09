local M = {}

function M.glob_to_lua(glob)
  local p = glob
    :gsub("([%.%+%-%^%$%(%)%[%]%{%}])", "%%%1") -- escape special chars
    :gsub("%*%*", "\1")                           -- ** → placeholder (avoid \0: empty match in Lua patterns)
    :gsub("%*", "[^/]*")                          -- * → any non-separator
    :gsub("\1", ".*")                             -- ** → anything
  return "^" .. p .. "$"
end

function M.matches_section(header, filename)
  local name = vim.fn.fnamemodify(filename, ":t")
  local rel  = vim.fn.fnamemodify(filename, ":.")
  for pattern in header:gmatch("[^,]+") do
    pattern = vim.trim(pattern)
    local lua_pat = M.glob_to_lua(pattern)
    if name:match(lua_pat) or rel:match(lua_pat) or ("/" .. rel):match(lua_pat) then
      return true
    end
  end
  return false
end

return M
