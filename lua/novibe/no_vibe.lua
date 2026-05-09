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

function M.load(filename)
  local dir = vim.fn.getcwd()
  for _ = 1, 10 do
    local novibe_path   = dir .. "/NO_VIBE.md"
    local novibe_dir    = dir .. "/.no_vibe"
    local convention_files   = vim.fn.glob(novibe_dir .. "/convention-*.md", false, true)
    local learned_files = vim.fn.glob(novibe_dir .. "/learned-*.md", false, true)
    local has_novibe    = vim.fn.filereadable(novibe_path) == 1
    local has_dir_files = #convention_files > 0 or #learned_files > 0

    if has_novibe or has_dir_files then
      local matched = {}
      parse_file(novibe_path, filename, matched)
      table.sort(convention_files)
      for _, path in ipairs(convention_files) do
        parse_file(path, filename, matched)
      end
      table.sort(learned_files)
      for _, path in ipairs(learned_files) do
        parse_file(path, filename, matched)
      end
      return #matched > 0 and table.concat(matched, "\n") or nil
    end

    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return nil
end

return M
