local act2 = require("novibe.act2")

describe("novibe.act2._build_prompt", function()
  local build = act2._build_prompt

  local selection = "local x = TODO"

  it("includes the selection with the 'code' field instruction", function()
    local prompt = build(selection, {}, {}, nil, nil, nil, "")
    assert.truthy(prompt:find("Selection to modify", 1, true))
    assert.truthy(prompt:find(selection, 1, true))
  end)

  it("includes ctx_before with header", function()
    local prompt = build(selection, { "line1", "line2" }, {}, nil, nil, nil, "")
    assert.truthy(prompt:find("Context before selection", 1, true))
    assert.truthy(prompt:find("line1", 1, true))
  end)

  it("omits ctx_before header when empty", function()
    local prompt = build(selection, {}, {}, nil, nil, nil, "")
    assert.falsy(prompt:find("Context before selection", 1, true))
  end)

  it("includes ctx_after with header", function()
    local prompt = build(selection, {}, { "after1" }, nil, nil, nil, "")
    assert.truthy(prompt:find("Context after selection", 1, true))
    assert.truthy(prompt:find("after1", 1, true))
  end)

  it("omits ctx_after header when empty", function()
    local prompt = build(selection, {}, {}, nil, nil, nil, "")
    assert.falsy(prompt:find("Context after selection", 1, true))
  end)

  it("includes no_vibe conventions when provided", function()
    local prompt = build(selection, {}, {}, "always: no semicolons", nil, nil, "")
    assert.truthy(prompt:find("Project conventions:", 1, true))
    assert.truthy(prompt:find("no semicolons", 1, true))
  end)

  it("omits conventions block when no_vibe_txt is nil", function()
    local prompt = build(selection, {}, {}, nil, nil, nil, "")
    assert.falsy(prompt:find("Project conventions:", 1, true))
  end)

  it("includes enclosing context when provided", function()
    local prompt = build(selection, {}, {}, nil, "function foo()", nil, "")
    assert.truthy(prompt:find("function foo()", 1, true))
  end)

  it("omits enclosing context when nil", function()
    local prompt = build(selection, { "before" }, {}, nil, nil, nil, "")
    -- enclosing would appear before ctx_before; check it's absent
    local ctx_pos = prompt:find("Context before", 1, true)
    -- no extra function signature line above the ctx_before header
    local head = prompt:sub(1, ctx_pos or #prompt)
    assert.falsy(head:find("function ", 1, true))
  end)

  it("appends diag_txt after the selection", function()
    local diag   = "E  file.lua:5  undefined 'foo'"
    local prompt = build(selection, {}, {}, nil, nil, diag, "")
    local sel_pos  = prompt:find("Selection to modify", 1, true)
    local diag_pos = prompt:find(diag, 1, true)
    assert.truthy(sel_pos)
    assert.truthy(diag_pos)
    assert.truthy(diag_pos > sel_pos)
  end)

  it("omits diag_txt when empty string", function()
    local diag   = "E  file.lua:5  some error"
    local prompt = build(selection, {}, {}, nil, nil, "", "")
    assert.falsy(prompt:find(diag, 1, true))
  end)

  it("includes user instruction when non-empty", function()
    local prompt = build(selection, {}, {}, nil, nil, nil, "use snake_case")
    assert.truthy(prompt:find("Instruction: use snake_case", 1, true))
  end)

  it("omits instruction line when user_prompt is empty", function()
    local prompt = build(selection, {}, {}, nil, nil, nil, "")
    assert.falsy(prompt:find("Instruction:", 1, true))
  end)

  it("ctx_before appears before selection", function()
    local prompt = build(selection, { "before_line" }, {}, nil, nil, nil, "")
    local before_pos = prompt:find("before_line", 1, true)
    local sel_pos    = prompt:find("Selection to modify", 1, true)
    assert.truthy(before_pos < sel_pos)
  end)

  it("selection appears before ctx_after", function()
    local prompt = build(selection, {}, { "after_line" }, nil, nil, nil, "")
    local sel_pos   = prompt:find("Selection to modify", 1, true)
    local after_pos = prompt:find("after_line", 1, true)
    assert.truthy(sel_pos < after_pos)
  end)

  it("instruction appears last", function()
    local diag   = "E diag line"
    local prompt = build(selection, { "b" }, { "a" }, "conv", "enc()", diag, "do it fast")
    local instr_pos = prompt:find("Instruction:", 1, true)
    local diag_pos  = prompt:find(diag, 1, true)
    assert.truthy(instr_pos > diag_pos)
  end)
end)
