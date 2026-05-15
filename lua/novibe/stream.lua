local M = {}

-- Extract the decoded value of the "code" JSON string field from partial or
-- complete JSON text. Returns the string (may be incomplete if the closing
-- quote hasn't arrived yet), or nil if the field hasn't started yet.
function M.extract_code(text)
  local after_quote = text:match('"code"%s*:%s*"()')
  if not after_quote then return nil end

  local result = {}
  local i = after_quote
  local n = #text

  while i <= n do
    local c = text:sub(i, i)
    if c == '"' then
      break
    elseif c == '\\' then
      if i >= n then break end
      local esc = text:sub(i + 1, i + 1)
      if     esc == '"'  then table.insert(result, '"');  i = i + 2
      elseif esc == '\\' then table.insert(result, '\\'); i = i + 2
      elseif esc == 'n'  then table.insert(result, '\n'); i = i + 2
      elseif esc == 't'  then table.insert(result, '\t'); i = i + 2
      elseif esc == 'r'  then table.insert(result, '\r'); i = i + 2
      elseif esc == '/'  then table.insert(result, '/');  i = i + 2
      elseif esc == 'b'  then table.insert(result, '\8'); i = i + 2
      elseif esc == 'f'  then table.insert(result, '\12'); i = i + 2
      elseif esc == 'u'  then
        if i + 5 > n then break end
        local hex = text:sub(i + 2, i + 5)
        local cp  = tonumber(hex, 16)
        if cp then
          -- vim.fn.nr2char(cp, 1) emits UTF-8 regardless of 'encoding';
          -- portable across luajit (no native utf8 lib) and Lua 5.3+.
          local ok, ch = pcall(vim.fn.nr2char, cp, 1)
          table.insert(result, ok and ch or '?')
        end
        i = i + 6
      else
        break
      end
    else
      table.insert(result, c)
      i = i + 1
    end
  end

  if #result == 0 then return nil end
  return table.concat(result)
end

return M
