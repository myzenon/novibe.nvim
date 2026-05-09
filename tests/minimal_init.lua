-- Minimal Neovim config for running tests via plenary.nvim
--
-- Plenary is expected to live in one of these locations (first hit wins):
--   ./deps/plenary.nvim                         (CI / cloned)
--   ~/.local/share/nvim/lazy/plenary.nvim       (LazyVim)
--   ~/.local/share/nvim/site/pack/*/start/plenary.nvim  (packer/native)
--
-- Run:  make test
-- Or:   nvim --headless -u tests/minimal_init.lua \
--         -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

local function find_plenary()
  local candidates = {
    vim.fn.getcwd() .. "/deps/plenary.nvim",
    vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
  }
  for _, c in ipairs(candidates) do
    if vim.fn.isdirectory(c) == 1 then return c end
  end
  -- fall back to glob in pack/*/start
  local matches = vim.fn.glob(vim.fn.expand("~/.local/share/nvim/site/pack/*/start/plenary.nvim"), false, true)
  if #matches > 0 then return matches[1] end
  return nil
end

local plenary = find_plenary()
if not plenary then
  io.stderr:write("plenary.nvim not found. Install it or clone into ./deps/plenary.nvim\n")
  os.exit(1)
end

vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:prepend(plenary)
vim.cmd("runtime plugin/plenary.vim")
