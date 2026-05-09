local glob = require("novibe.glob")
local M = {}

local function parse_file(path, filename, matched)
  if vim.fn.filereadable(path) == 0 then return end
  local lines        = vim.fn.readfile(path)
  local cur_header   = nil
  local cur_body     = {}

  local function flush()
    if not cur_header then return end
    local body = vim.trim(table.concat(cur_body, "\n"))
    if body == "" then return end
    if cur_header:lower() == "always" then
      table.insert(matched, 1, body)
    elseif filename and glob.matches_section(cur_header, filename) then
      table.insert(matched, body)
    end
  end

  for _, line in ipairs(lines) do
    local header = line:match("^##%s*(.+)$")
    if header then
      flush()
      cur_header = vim.trim(header)
      cur_body   = {}
    elseif cur_header and not line:match("^<!%-%-") then
      table.insert(cur_body, line)
    end
  end
  flush()
end

-- Walk up from cwd looking for NO_VIBE.md or .no_vibe/ with content.
-- Returns { root = dir, novibe_md = path|nil, conventions = {paths}, learned = {paths} } or nil.
function M.discover()
  local dir = vim.fn.getcwd()
  for _ = 1, 10 do
    local novibe_path      = dir .. "/NO_VIBE.md"
    local novibe_dir       = dir .. "/.no_vibe"
    local convention_files = vim.fn.glob(novibe_dir .. "/convention-*.md", false, true)
    local learned_files    = vim.fn.glob(novibe_dir .. "/learned-*.md", false, true)
    local has_novibe       = vim.fn.filereadable(novibe_path) == 1

    if has_novibe or #convention_files > 0 or #learned_files > 0 then
      table.sort(convention_files)
      table.sort(learned_files)
      return {
        root        = dir,
        novibe_md   = has_novibe and novibe_path or nil,
        conventions = convention_files,
        learned     = learned_files,
      }
    end

    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return nil
end

function M.load(filename)
  local found = M.discover()
  if not found then return nil end

  local matched = {}
  if found.novibe_md then parse_file(found.novibe_md, filename, matched) end
  for _, path in ipairs(found.conventions) do parse_file(path, filename, matched) end
  for _, path in ipairs(found.learned) do parse_file(path, filename, matched) end
  return #matched > 0 and table.concat(matched, "\n") or nil
end

return M
