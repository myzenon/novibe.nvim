local M = {}

local SEV = { [1] = "Error", [2] = "Warning", [3] = "Info", [4] = "Hint" }

-- Returns a formatted diagnostics string, or nil if none.
-- line_start/line_end are 1-based inclusive; omit to include the whole buffer.
function M.format(bufnr, line_start, line_end)
  local diags = vim.diagnostic.get(bufnr)
  if #diags == 0 then return nil end

  if line_start and line_end then
    local s, e = line_start - 1, line_end - 1
    local filtered = {}
    for _, d in ipairs(diags) do
      if d.lnum >= s and d.lnum <= e then
        table.insert(filtered, d)
      end
    end
    diags = filtered
  end

  if #diags == 0 then return nil end

  table.sort(diags, function(a, b) return a.lnum < b.lnum end)

  local lines = { "LSP diagnostics:" }
  for _, d in ipairs(diags) do
    local sev = SEV[d.severity] or "Info"
    local src = d.source and (" (" .. d.source .. ")") or ""
    table.insert(lines, string.format("  line %d: [%s] %s%s", d.lnum + 1, sev, d.message, src))
  end
  return table.concat(lines, "\n")
end

return M
