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
