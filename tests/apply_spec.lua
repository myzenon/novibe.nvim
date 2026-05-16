local apply = require("novibe.apply")

local function tmp_file(content)
  local path = vim.fn.tempname()
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
  return path
end

local function read_file(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local function cleanup(path)
  vim.fn.delete(path)
  local bufnr = vim.fn.bufnr(vim.fn.fnamemodify(path, ":p"))
  if bufnr ~= -1 then vim.api.nvim_buf_delete(bufnr, { force = true }) end
end

describe("apply — replace action", function()
  it("replaces an exact-match block", function()
    local path = tmp_file("line1\nline2\nline3")
    local ok, err = apply.apply({ file = path, action = "replace", find = "line2", replace = "replaced" })
    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals("line1\nreplaced\nline3", read_file(path))
    cleanup(path)
  end)

  it("matches with leading/trailing whitespace differences (strict pass)", function()
    local path = tmp_file("function foo()\n  return 1\nend")
    local ok = apply.apply({ file = path, action = "replace", find = "  return 1", replace = "  return 2" })
    assert.is_true(ok)
    assert.truthy(read_file(path):find("return 2"))
    cleanup(path)
  end)

  it("matches across blank line count differences (lenient pass)", function()
    local path = tmp_file("foo()\n\n\nbar()")
    -- find has one blank line, file has two — lenient should still match
    local ok = apply.apply({ file = path, action = "replace", find = "foo()\n\nbar()", replace = "baz()" })
    assert.is_true(ok)
    assert.truthy(read_file(path):find("baz"))
    cleanup(path)
  end)

  it("returns false when block not found", function()
    local path = tmp_file("line1\nline2")
    local ok, err = apply.apply({ file = path, action = "replace", find = "nothere", replace = "x" })
    assert.is_false(ok)
    assert.truthy(err:find(vim.fn.fnamemodify(path, ":t")))
    cleanup(path)
  end)

  it("returns false on empty find block", function()
    local path = tmp_file("line1")
    local ok, err = apply.apply({ file = path, action = "replace", find = "   ", replace = "x" })
    assert.is_false(ok)
    assert.is_string(err)
    cleanup(path)
  end)
end)

describe("apply — insert_after action", function()
  it("inserts new lines immediately after the matched block", function()
    local path = tmp_file("aaa\nbbb\nccc")
    local ok = apply.apply({ file = path, action = "insert_after", find = "bbb", replace = "inserted" })
    assert.is_true(ok)
    local result = read_file(path)
    local bbb_pos      = result:find("bbb")
    local inserted_pos = result:find("inserted")
    assert.truthy(inserted_pos > bbb_pos)
    assert.truthy(result:find("ccc"))
    cleanup(path)
  end)

  it("preserves the matched block unchanged", function()
    local path = tmp_file("aaa\nbbb\nccc")
    apply.apply({ file = path, action = "insert_after", find = "bbb", replace = "inserted" })
    assert.truthy(read_file(path):find("bbb"))
    cleanup(path)
  end)
end)

describe("apply — insert_before action", function()
  it("inserts new lines immediately before the matched block", function()
    local path = tmp_file("aaa\nbbb\nccc")
    local ok = apply.apply({ file = path, action = "insert_before", find = "bbb", replace = "inserted" })
    assert.is_true(ok)
    local result = read_file(path)
    local inserted_pos = result:find("inserted")
    local bbb_pos      = result:find("bbb")
    assert.truthy(inserted_pos < bbb_pos)
    cleanup(path)
  end)
end)

describe("apply — error cases", function()
  it("returns false when file does not exist", function()
    local ok, err = apply.apply({ file = "/nonexistent/path/file.lua", action = "replace", find = "x", replace = "y" })
    assert.is_false(ok)
    assert.truthy(err:find("file not found"))
  end)

  it("returns false on unknown action", function()
    local path = tmp_file("hello")
    local ok, err = apply.apply({ file = path, action = "delete", find = "hello", replace = "" })
    assert.is_false(ok)
    assert.truthy(err:find("unknown action"))
    cleanup(path)
  end)
end)

describe("apply — create action", function()
  it("writes a new file with the given content", function()
    local path = vim.fn.tempname() .. "_create_test.lua"
    local ok, err = apply.apply({ file = path, action = "create", find = "", replace = "local x = 1\nreturn x" })
    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals("local x = 1\nreturn x", read_file(path))
    vim.fn.delete(path)
  end)

  it("creates missing parent directories", function()
    local base = vim.fn.tempname()
    vim.fn.mkdir(base, "p")
    local path = base .. "/nested/dir/file.lua"
    local ok = apply.apply({ file = path, action = "create", find = "", replace = "-- hi" })
    assert.is_true(ok)
    assert.equals("-- hi", read_file(path))
    vim.fn.delete(base, "rf")
  end)

  it("returns false if the file already exists", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ "existing" }, path)
    local ok, err = apply.apply({ file = path, action = "create", find = "", replace = "new" })
    assert.is_false(ok)
    assert.truthy(err:find("already exists"))
    assert.equals("existing", read_file(path))  -- original untouched
    vim.fn.delete(path)
  end)

  it("returns false when replace is missing", function()
    local path = vim.fn.tempname() .. "_no_replace.lua"
    local ok, err = apply.apply({ file = path, action = "create", find = "" })
    assert.is_false(ok)
    assert.truthy(err:find("missing 'replace'"))
  end)
end)

describe("apply_all", function()
  it("applies multiple changes in order", function()
    local path = tmp_file("aaa\nbbb\nccc")
    apply.apply_all({
      { file = path, action = "replace", find = "aaa", replace = "AAA" },
      { file = path, action = "replace", find = "ccc", replace = "CCC" },
    })
    local result = read_file(path)
    assert.truthy(result:find("AAA"))
    assert.truthy(result:find("CCC"))
    assert.truthy(result:find("bbb"))
    cleanup(path)
  end)

  it("continues applying remaining changes after one fails", function()
    local path = tmp_file("aaa\nbbb")
    apply.apply_all({
      { file = path, action = "replace", find = "nothere", replace = "x" },
      { file = path, action = "replace", find = "bbb", replace = "BBB" },
    })
    assert.truthy(read_file(path):find("BBB"))
    cleanup(path)
  end)
end)
