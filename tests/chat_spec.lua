local chat = require("novibe.chat")

describe("chat._normalize_changes", function()
  local norm = chat._normalize_changes

  it("returns empty table for nil", function()
    assert.same({}, norm(nil))
  end)

  it("returns empty table for vim.NIL", function()
    assert.same({}, norm(vim.NIL))
  end)

  it("returns empty table for non-table types", function()
    assert.same({}, norm("not a table"))
    assert.same({}, norm(42))
    assert.same({}, norm(false))
  end)

  it("passes through a real list unchanged", function()
    local list = { { file = "a.lua" }, { file = "b.lua" } }
    assert.equals(list, norm(list))
  end)

  it("passes through an empty table", function()
    local empty = {}
    assert.equals(empty, norm(empty))
  end)
end)

describe("chat._buf_context", function()
  local buf_context = chat._buf_context

  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  it("returns empty tables for an invalid buffer", function()
    local before, after = buf_context(99999, 3, 3, 2)
    assert.same({}, before)
    assert.same({}, after)
  end)

  it("returns N lines before start_line", function()
    local buf = make_buf({ "a", "b", "c", "d", "e" })
    local before, _ = buf_context(buf, 3, 3, 2)
    assert.same({ "a", "b" }, before)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns N lines after end_line", function()
    local buf = make_buf({ "a", "b", "c", "d", "e" })
    local _, after = buf_context(buf, 3, 3, 2)
    assert.same({ "d", "e" }, after)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("clamps before context to start of buffer", function()
    local buf = make_buf({ "a", "b", "c" })
    local before, _ = buf_context(buf, 1, 1, 5)
    assert.same({}, before)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("clamps after context to end of buffer", function()
    local buf = make_buf({ "a", "b", "c" })
    local _, after = buf_context(buf, 3, 3, 5)
    assert.same({}, after)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("handles a multi-line selection", function()
    local buf = make_buf({ "a", "b", "c", "d", "e", "f" })
    -- selection is lines 2-4 (1-based)
    local before, after = buf_context(buf, 2, 4, 1)
    assert.same({ "a" }, before)
    assert.same({ "e" }, after)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("chat._file_context", function()
  local file_context = chat._file_context

  local function write_tmp(lines)
    local path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile(lines, path)
    return path
  end

  it("returns empty tables + nil for a non-existent file", function()
    local before, after, ms = file_context("/no/such/file.txt", "anything", 3)
    assert.same({}, before)
    assert.same({}, after)
    assert.is_nil(ms)
  end)

  it("returns empty tables + nil when find_text is not in the file", function()
    local path = write_tmp({ "line1", "line2", "line3" })
    local before, after, ms = file_context(path, "not here", 3)
    assert.same({}, before)
    assert.same({}, after)
    assert.is_nil(ms)
    vim.fn.delete(path)
  end)

  it("returns match_start (1-based) when find_text is found", function()
    local path = write_tmp({ "a", "b", "target", "d", "e" })
    local _, _, ms = file_context(path, "target", 3)
    assert.equals(3, ms)
    vim.fn.delete(path)
  end)

  it("returns N lines before the match", function()
    local path = write_tmp({ "a", "b", "c", "target", "e", "f" })
    local before, _, _ = file_context(path, "target", 2)
    assert.same({ "b", "c" }, before)
    vim.fn.delete(path)
  end)

  it("returns N lines after the match", function()
    local path = write_tmp({ "a", "b", "target", "d", "e", "f" })
    local _, after, _ = file_context(path, "target", 2)
    assert.same({ "d", "e" }, after)
    vim.fn.delete(path)
  end)

  it("clamps before context to start of file", function()
    local path = write_tmp({ "target", "b", "c" })
    local before, _, ms = file_context(path, "target", 3)
    assert.same({}, before)
    assert.equals(1, ms)
    vim.fn.delete(path)
  end)

  it("clamps after context to end of file", function()
    local path = write_tmp({ "a", "b", "target" })
    local _, after, _ = file_context(path, "target", 3)
    assert.same({}, after)
    vim.fn.delete(path)
  end)

  it("matches multi-line find_text and reports correct match_start", function()
    local path = write_tmp({ "a", "line1", "line2", "d" })
    local _, _, ms = file_context(path, "line1\nline2", 1)
    assert.equals(2, ms)
    vim.fn.delete(path)
  end)

  it("ignores leading/trailing whitespace when matching", function()
    local path = write_tmp({ "a", "  target  ", "b" })
    local _, _, ms = file_context(path, "target", 1)
    assert.equals(2, ms)
    vim.fn.delete(path)
  end)
end)
