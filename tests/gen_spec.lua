local gen = require("novibe.gen")

describe("novibe.gen._build_prompt", function()
  local build = gen._build_prompt

  local root        = "/home/user/myproject"
  local description = "create a UserRepository class"

  it("includes project root and request description", function()
    local prompt = build(description, nil, root, nil)
    assert.truthy(prompt:find("Project root: " .. root, 1, true))
    assert.truthy(prompt:find("Request: " .. description, 1, true))
  end)

  it("includes buf_name from ctx as reference file", function()
    local prompt = build(description, { buf_name = "src/auth.ts" }, root, nil)
    assert.truthy(prompt:find("Reference file: src/auth.ts", 1, true))
  end)

  it("omits reference file when ctx.buf_name is empty", function()
    local prompt = build(description, { buf_name = "" }, root, nil)
    assert.falsy(prompt:find("Reference file:", 1, true))
  end)

  it("includes selection from ctx as reference code", function()
    local sel    = "export class AuthService {}"
    local prompt = build(description, { buf_name = "src/auth.ts", selection = sel }, root, nil)
    assert.truthy(prompt:find("Reference code:", 1, true))
    assert.truthy(prompt:find(sel, 1, true))
  end)

  it("omits reference code when ctx.selection is empty", function()
    local prompt = build(description, { buf_name = "src/auth.ts", selection = "" }, root, nil)
    assert.truthy(prompt:find("Reference file:", 1, true))
    assert.falsy(prompt:find("Reference code:", 1, true))
  end)

  it("appends diag_txt after the request line", function()
    local diag   = "E  src/auth.ts:10  undefined variable 'foo'"
    local prompt = build(description, { diag_txt = diag }, root, nil)
    local req_pos  = prompt:find("Request:", 1, true)
    local diag_pos = prompt:find(diag, 1, true)
    assert.truthy(req_pos)
    assert.truthy(diag_pos)
    assert.truthy(diag_pos > req_pos)
  end)

  it("omits diag_txt when empty string", function()
    local diag   = "E  src/auth.ts:10  some error"
    local prompt = build(description, { diag_txt = "" }, root, nil)
    assert.falsy(prompt:find(diag, 1, true))
  end)

  it("omits diag_txt when nil", function()
    local prompt = build(description, { diag_txt = nil }, root, nil)
    -- ensure no extra blank junk — just verify the request is last meaningful content
    local req_pos = prompt:find("Request:", 1, true)
    assert.truthy(req_pos)
    -- nothing meaningful after request + description
    local tail = prompt:sub(req_pos)
    assert.falsy(tail:find("\nE ", 1, true))
  end)

  it("includes no_vibe_txt conventions when provided", function()
    local prompt = build(description, nil, root, "always: no semicolons")
    assert.truthy(prompt:find("Project conventions:", 1, true))
    assert.truthy(prompt:find("no semicolons", 1, true))
  end)

  it("omits conventions block when no_vibe_txt is nil", function()
    local prompt = build(description, nil, root, nil)
    assert.falsy(prompt:find("Project conventions:", 1, true))
  end)

  it("works with nil ctx", function()
    local prompt = build(description, nil, root, nil)
    assert.truthy(prompt:find("Request: " .. description, 1, true))
    assert.falsy(prompt:find("Reference file:", 1, true))
  end)

  it("works with empty ctx table", function()
    local prompt = build(description, {}, root, nil)
    assert.truthy(prompt:find("Request: " .. description, 1, true))
    assert.falsy(prompt:find("Reference file:", 1, true))
  end)
end)
