local M = {}

local CONTAINER_TYPES = {
  -- generic / multi-language
  function_definition = true,  function_declaration = true,
  method_definition   = true,  method_declaration   = true,
  function_expression = true,  arrow_function       = true,
  -- Lua
  ["function"]        = true,  local_function       = true,
  -- Python
  function_def        = true,  class_definition     = true,
  -- Rust
  function_item       = true,  impl_item            = true,
  -- Go
  func_literal        = true,
  -- JS/TS
  method_signature    = true,
  -- general OOP
  class_declaration   = true,
}

-- Returns a formatted string describing the enclosing function/class for
-- `start_line` (1-based), or nil if none found or already in ctx_before.
-- `ctx_before_top` is the topmost line already sent as context (1-based),
-- so we only inject if the container starts above that.
function M.enclosing(bufnr, start_line, ctx_before_top)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return nil end

  local trees = parser:parse()
  if not trees or not trees[1] then return nil end

  local lnum = start_line - 1  -- 0-based
  local node = trees[1]:root():named_descendant_for_range(lnum, 0, lnum, 0)
  if not node then return nil end

  -- Walk up to find the innermost function/class container
  local cur = node:parent()
  while cur do
    if CONTAINER_TYPES[cur:type()] then
      local fn_start = cur:start() + 1  -- convert to 1-based
      -- Only inject if this node is above what ctx_before already covers
      if fn_start < ctx_before_top then
        local sig_end = math.min(fn_start + 7, ctx_before_top - 1)
        if sig_end >= fn_start then
          local lines = vim.api.nvim_buf_get_lines(bufnr, fn_start - 1, sig_end, false)
          while #lines > 0 and lines[#lines]:match("^%s*$") do
            table.remove(lines)
          end
          if #lines > 0 then
            return "Enclosing function (above context window):\n" .. table.concat(lines, "\n")
          end
        end
      end
      break
    end
    cur = cur:parent()
  end

  return nil
end

return M
