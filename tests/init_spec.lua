local init = require("novibe")

describe("novibe._build_gen_prompt", function()
  local build = init._build_gen_prompt

  local root        = "/home/user/myproject"
  local description = "create a User repository"

  it("includes the GEN_SYSTEM header, project root, and request", function()
    local prompt = build(description, root, nil, "", "")
    assert.truthy(prompt:find("Project root: " .. root, 1, true))
    assert.truthy(prompt:find("Request: " .. description, 1, true))
  end)

  it("includes project conventions when provided", function()
    local prompt = build(description, root, "always: no semicolons", "", "")
    assert.truthy(prompt:find("Project conventions:", 1, true))
    assert.truthy(prompt:find("no semicolons", 1, true))
  end)

  it("omits the conventions block when no_vibe_txt is nil", function()
    local prompt = build(description, root, nil, "", "")
    assert.falsy(prompt:find("Project conventions:", 1, true))
  end)

  it("includes reference file when buf_name is non-empty", function()
    local prompt = build(description, root, nil, "src/auth.service.ts", "")
    assert.truthy(prompt:find("Reference file: src/auth.service.ts", 1, true))
  end)

  it("omits reference file when buf_name is empty", function()
    local prompt = build(description, root, nil, "", "")
    assert.falsy(prompt:find("Reference file:", 1, true))
  end)

  it("omits reference file when buf_name is nil", function()
    local prompt = build(description, root, nil, nil, nil)
    assert.falsy(prompt:find("Reference file:", 1, true))
  end)

  it("includes reference code when selection is non-empty", function()
    local sel    = "export class AuthService {}"
    local prompt = build(description, root, nil, "src/auth.service.ts", sel)
    assert.truthy(prompt:find("Reference code:", 1, true))
    assert.truthy(prompt:find(sel, 1, true))
  end)

  it("omits reference code when selection is empty string", function()
    local prompt = build(description, root, nil, "src/auth.service.ts", "")
    assert.truthy(prompt:find("Reference file:", 1, true))
    assert.falsy(prompt:find("Reference code:", 1, true))
  end)

  it("omits reference code when selection is whitespace only", function()
    local prompt = build(description, root, nil, "src/auth.service.ts", "   \n  ")
    assert.truthy(prompt:find("Reference file:", 1, true))
    assert.falsy(prompt:find("Reference code:", 1, true))
  end)

  it("reference file appears before the request", function()
    local prompt = build(description, root, nil, "src/auth.service.ts", "some code")
    local ref_pos = prompt:find("Reference file:", 1, true)
    local req_pos = prompt:find("Request:", 1, true)
    assert.truthy(ref_pos < req_pos)
  end)

  it("reference code appears before the request", function()
    local prompt = build(description, root, nil, "src/foo.ts", "const x = 1")
    local code_pos = prompt:find("Reference code:", 1, true)
    local req_pos  = prompt:find("Request:", 1, true)
    assert.truthy(code_pos < req_pos)
  end)
end)
