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

-- Parse a file with glob-section filtering (used for NO_VIBE.md and act/learned-*.md).
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

-- Parse config.md sections by mode.
-- mode="act"   → include ## Always and ## Act
-- mode="agent" → include ## Always and ## Agent
local function parse_config(path, mode, matched)
  if vim.fn.filereadable(path) == 0 then return end
  local lines      = vim.fn.readfile(path)
  local cur_header = nil
  local cur_body   = {}

  local function want(h)
    local lower = h:lower()
    if lower == "always" then return true end
    if mode == "act"   and lower == "act"   then return true end
    if mode == "agent" and lower == "agent" then return true end
    return false
  end

  local function flush()
    if not cur_header or not want(cur_header) then return end
    local body = vim.trim(table.concat(cur_body, "\n"))
    if body == "" then return end
    if cur_header:lower() == "always" then
      table.insert(matched, 1, body)
    else
      table.insert(matched, body)
    end
  end

  for _, line in ipairs(lines) do
    local header = line:match("^##%s*(.+)$")
    if header then
      flush()
      cur_header = vim.trim(header)
      cur_body   = {}
    elseif cur_header then
      if not line:match("^<!%-%-") then
        table.insert(cur_body, line)
      end
    end
  end
  flush()
end

-- Parse topics/index.md: return list of "topics/<area>" paths matching filename.
-- Section format: "## Area Name [glob]" or "## Always" (no glob).
-- Body may contain "- topics/<area>/" bullet entries.
local function parse_index(path, filename)
  if vim.fn.filereadable(path) == 0 then return {} end
  local lines    = vim.fn.readfile(path)
  local cur_name = nil
  local cur_glob = nil
  local cur_dirs = {}
  local result   = {}

  local function flush()
    if not cur_name then return end
    local matches = false
    if cur_name:lower() == "always" then
      matches = true
    elseif cur_glob and filename then
      matches = glob.matches_section(cur_glob, filename)
    end
    if matches then vim.list_extend(result, cur_dirs) end
  end

  for _, line in ipairs(lines) do
    local header = line:match("^##%s*(.+)$")
    if header then
      flush()
      header = vim.trim(header)
      local name, g = header:match("^(.-)%s*%[(.-)%]%s*$")
      if name and g then
        cur_name = vim.trim(name)
        cur_glob = vim.trim(g)
      else
        cur_name = header
        cur_glob = nil
      end
      cur_dirs = {}
    elseif cur_name then
      local dir = line:match("^%s*%-%s*(topics/[^%s]+)")
      if dir then
        table.insert(cur_dirs, (dir:gsub("/$", "")))
      end
    end
  end
  flush()
  return result
end

-- Walk up from cwd to find the nearest directory containing a .no_vibe/ subdirectory.
-- Returns the .no_vibe/ path, or nil.
function M.find_novibe_dir()
  local dir = vim.fn.getcwd()
  for _ = 1, 10 do
    if vim.fn.isdirectory(dir .. "/.no_vibe") == 1 then
      return dir .. "/.no_vibe"
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return nil
end

-- Walk up from cwd looking for NO_VIBE.md or .no_vibe/.
-- Returns { root, novibe_dir, novibe_md, has_topics, has_config, learned } or nil.
function M.discover()
  local dir = vim.fn.getcwd()
  for _ = 1, 10 do
    local novibe_dir  = dir .. "/.no_vibe"
    local novibe_path = dir .. "/NO_VIBE.md"
    local has_dir     = vim.fn.isdirectory(novibe_dir) == 1
    local has_novibe  = vim.fn.filereadable(novibe_path) == 1

    if has_dir or has_novibe then
      local learned = vim.fn.glob(novibe_dir .. "/act/learned-*.md", false, true)
      table.sort(learned)
      return {
        root       = dir,
        novibe_dir = novibe_dir,
        novibe_md  = has_novibe and novibe_path or nil,
        has_topics = vim.fn.isdirectory(novibe_dir .. "/topics") == 1,
        has_config = vim.fn.filereadable(novibe_dir .. "/config.md") == 1,
        learned    = learned,
      }
    end

    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return nil
end

-- Load KB content for the given filename and mode.
-- mode="act"   (default) → config Always+Act, matched topic rule.md, act/learned-*.md
-- mode="agent"           → config Always+Agent, matched topic rule.md
function M.load(filename, mode)
  mode = mode or "act"
  local found = M.discover()
  if not found then return nil end

  local matched = {}

  -- 1. NO_VIBE.md (glob-section filtered, simple-project shortcut)
  if found.novibe_md then
    parse_file(found.novibe_md, filename, matched)
  end

  -- 2. config.md (section filtered by mode)
  if found.has_config then
    parse_config(found.novibe_dir .. "/config.md", mode, matched)
  end

  -- 3. topics/index.md → load rule.md for each matched area
  if found.has_topics then
    local dirs = parse_index(found.novibe_dir .. "/topics/index.md", filename)
    for _, rel_dir in ipairs(dirs) do
      local rule_path = found.novibe_dir .. "/" .. rel_dir .. "/rule.md"
      if vim.fn.filereadable(rule_path) == 1 then
        local content = vim.trim(table.concat(vim.fn.readfile(rule_path), "\n"))
        if content ~= "" then table.insert(matched, content) end
      end
    end
  end

  -- 4. act/learned-*.md (glob-section filtered, act mode only)
  if mode == "act" then
    for _, path in ipairs(found.learned) do
      parse_file(path, filename, matched)
    end
  end

  return #matched > 0 and table.concat(matched, "\n") or nil
end

return M
