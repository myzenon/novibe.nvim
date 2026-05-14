local glob = require("novibe.glob")
local M = {}

-- Check if a knowledge section is stale by comparing git history since last-verified hash.
-- Only meaningful for directory-style headers like `src/db/**` — skips extension patterns.
local function stale_warning(hash, header)
  if not hash or hash == "" then return nil end
  if not header:find("/") then return nil end
  local git_path = header:match("^([^%*]+)")
  if not git_path or git_path == "" then return nil end
  git_path = git_path:gsub("/$", "")
  if git_path == "" then return nil end
  local result = vim.fn.system(
    "git log " .. vim.fn.shellescape(hash) .. "..HEAD --oneline -- " .. vim.fn.shellescape(git_path) .. " 2>/dev/null"
  )
  if not result or not result:match("%S") then return nil end
  local count = 0
  for _ in (result .. "\n"):gmatch("[^\n]+") do count = count + 1 end
  return "⚠ STALE: " .. git_path .. " has " .. count .. " commit(s) since " .. hash:sub(1, 7) .. " — verify before trusting."
end

local function parse_file(path, filename, matched)
  if vim.fn.filereadable(path) == 0 then return end
  local lines      = vim.fn.readfile(path)
  local cur_header = nil
  local cur_body   = {}
  local cur_hash   = nil

  local function flush()
    if not cur_header then return end
    local body = vim.trim(table.concat(cur_body, "\n"))
    if body == "" then return end
    local warning = stale_warning(cur_hash, cur_header)
    local content = warning and (warning .. "\n" .. body) or body
    if cur_header:lower() == "always" then
      table.insert(matched, 1, content)
    elseif filename and glob.matches_section(cur_header, filename) then
      table.insert(matched, content)
    end
  end

  for _, line in ipairs(lines) do
    local header = line:match("^##%s*(.+)$")
    if header then
      flush()
      cur_header = vim.trim(header)
      cur_body   = {}
      cur_hash   = nil
    elseif cur_header then
      local lv = line:match("^<!%-%-%s*last%-verified:%s*([%x]+)%s*%-%->")
      if lv then
        cur_hash = lv
      elseif not line:match("^<!%-%-") then
        table.insert(cur_body, line)
      end
    end
  end
  flush()
end

-- Walk up from cwd looking for NO_VIBE.md or .no_vibe/ with content.
-- Returns { root, novibe_md, conventions, learned, knowledge } or nil.
function M.discover()
  local dir = vim.fn.getcwd()
  for _ = 1, 10 do
    local novibe_path      = dir .. "/NO_VIBE.md"
    local novibe_dir       = dir .. "/.no_vibe"
    local convention_files = vim.fn.glob(novibe_dir .. "/convention-*.md", false, true)
    local learned_files    = vim.fn.glob(novibe_dir .. "/learned-*.md", false, true)
    local map_files        = vim.fn.glob(novibe_dir .. "/map-*.md", false, true)
    local rule_files       = vim.fn.glob(novibe_dir .. "/rule-*.md", false, true)
    local decision_files   = vim.fn.glob(novibe_dir .. "/decision-*.md", false, true)
    local has_novibe       = vim.fn.filereadable(novibe_path) == 1
    local has_knowledge    = #map_files > 0 or #rule_files > 0 or #decision_files > 0

    if has_novibe or #convention_files > 0 or #learned_files > 0 or has_knowledge then
      table.sort(convention_files)
      table.sort(learned_files)
      table.sort(map_files)
      table.sort(rule_files)
      table.sort(decision_files)
      local knowledge = {}
      vim.list_extend(knowledge, map_files)
      vim.list_extend(knowledge, rule_files)
      vim.list_extend(knowledge, decision_files)
      return {
        root        = dir,
        novibe_md   = has_novibe and novibe_path or nil,
        conventions = convention_files,
        learned     = learned_files,
        knowledge   = knowledge,
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
  for _, path in ipairs(found.learned)     do parse_file(path, filename, matched) end
  for _, path in ipairs(found.knowledge)   do parse_file(path, filename, matched) end
  return #matched > 0 and table.concat(matched, "\n") or nil
end

return M
