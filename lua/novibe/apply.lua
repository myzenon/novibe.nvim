local M = {}

local function norm(line) return vim.trim(line) end

local function to_norm_lines(text)
  return vim.tbl_map(norm, vim.split(vim.trim(text), "\n", { plain = true }))
end

local function strip_empty(lines)
  local s, e = 1, #lines
  while s <= e and lines[s] == "" do s = s + 1 end
  while e >= s and lines[e] == "" do e = e - 1 end
  return vim.list_slice(lines, s, e)
end

local function find_strict(norm_file, pattern)
  pattern = strip_empty(pattern)
  if #pattern == 0 then return nil, nil end
  for i = 1, #norm_file - #pattern + 1 do
    local ok = true
    for j = 1, #pattern do
      if norm_file[i + j - 1] ~= pattern[j] then ok = false; break end
    end
    if ok then return i, i + #pattern - 1 end
  end
  return nil, nil
end

local function find_lenient(norm_file, find_text)
  local pattern_nonblank = vim.tbl_filter(
    function(l) return l ~= "" end,
    to_norm_lines(find_text)
  )
  if #pattern_nonblank == 0 then return nil, nil end

  local file_nonblank = {}
  for i, l in ipairs(norm_file) do
    if l ~= "" then table.insert(file_nonblank, { idx = i, val = l }) end
  end

  for i = 1, #file_nonblank - #pattern_nonblank + 1 do
    local ok = true
    for j = 1, #pattern_nonblank do
      if file_nonblank[i + j - 1].val ~= pattern_nonblank[j] then ok = false; break end
    end
    if ok then
      return file_nonblank[i].idx, file_nonblank[i + #pattern_nonblank - 1].idx
    end
  end
  return nil, nil
end

local function find_range(file_lines, find_text)
  local norm_file = vim.tbl_map(norm, file_lines)
  local pattern   = to_norm_lines(find_text)

  local s, e = find_strict(norm_file, pattern)
  if s then return s, e end

  return find_lenient(norm_file, find_text)
end

local function get_buf(filepath)
  local abs = vim.fn.fnamemodify(filepath, ":p")
  if vim.fn.filereadable(abs) == 0 then
    return nil, "file not found: " .. filepath
  end
  local bufnr = vim.fn.bufnr(abs)
  if bufnr == -1 then
    bufnr = vim.fn.bufadd(abs)
    vim.fn.bufload(bufnr)
  end
  return bufnr, nil
end

function M.apply(change)
  if type(change.file) ~= "string" or change.file == "" then
    return false, "change is missing 'file'"
  end
  if type(change.replace) ~= "string" then
    return false, "change for " .. change.file .. " is missing 'replace'"
  end

  local action = (type(change.action) == "string" and change.action ~= "")
    and change.action or "replace"

  -- create: write a brand-new file; no find/replace matching needed
  if action == "create" then
    local abs = vim.fn.fnamemodify(change.file, ":p")
    if vim.fn.filereadable(abs) == 1 then
      return false, "file already exists: " .. change.file .. " — use action 'replace' or revise the path with :w"
    end
    vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
    vim.fn.writefile(vim.split(change.replace, "\n", { plain = true }), abs)
    return true, nil
  end

  if type(change.find) ~= "string" then
    return false, "change for " .. change.file .. " is missing 'find'"
  end

  local bufnr, err = get_buf(change.file)
  if not bufnr then return false, err end

  local file_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local s, e = find_range(file_lines, change.find)
  if not s then
    local snippet = change.find:sub(1, 80):gsub("\n", "↵")
    return false, "could not locate block in " .. change.file .. "\nSearched for: " .. snippet
  end

  local new_lines = vim.split(change.replace, "\n", { plain = true })

  if action == "replace" then
    vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, new_lines)
  elseif action == "insert_after" then
    vim.api.nvim_buf_set_lines(bufnr, e, e, false, new_lines)
  elseif action == "insert_before" then
    vim.api.nvim_buf_set_lines(bufnr, s - 1, s - 1, false, new_lines)
  else
    return false, "unknown action: " .. action
  end

  vim.api.nvim_buf_call(bufnr, function() vim.cmd("write") end)
  return true, nil
end

function M.apply_all(changes)
  local errors = {}
  for _, change in ipairs(changes) do
    local ok, e = M.apply(change)
    if not ok then table.insert(errors, e) end
  end
  if #errors > 0 then
    vim.notify("novibe apply errors:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
  else
    vim.notify("novibe: " .. #changes .. " change(s) applied", vim.log.levels.INFO)
  end
end

return M
