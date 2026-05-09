local glob = require("novibe.glob")

describe("glob_to_lua", function()
  it("converts * to non-separator wildcard", function()
    local pat = glob.glob_to_lua("*.tsx")
    assert.truthy(string.match("Button.tsx", pat))
    assert.falsy(string.match("src/Button.tsx", pat))
  end)

  it("converts ** to any-path wildcard", function()
    local pat = glob.glob_to_lua("**/tests/**")
    assert.truthy(string.match("src/foo/tests/bar.ts", pat))
    -- glob_to_lua generates ^.*/tests/.*$ which needs a leading "/"
    -- matches_section handles this by also trying "/" .. rel
    assert.truthy(string.match("/tests/bar.ts", pat))
  end)

  it("treats dots as literals not wildcards", function()
    local pat = glob.glob_to_lua("*.test.ts")
    assert.truthy(string.match("foo.test.ts", pat))
    assert.falsy(string.match("footestXts", pat))
  end)

  it("escapes other Lua special chars", function()
    local pat = glob.glob_to_lua("foo+bar.ts")
    assert.truthy(string.match("foo+bar.ts", pat))
    assert.falsy(string.match("fooXbar.ts", pat))
  end)

  it("anchors at both ends so partial matches fail", function()
    local pat = glob.glob_to_lua("*.ts")
    assert.falsy(string.match("foo.tsx", pat))
    assert.truthy(string.match("foo.ts", pat))
  end)
end)

describe("matches_section", function()
  it("matches against basename when pattern has no path separator", function()
    assert.is_true(glob.matches_section("*.tsx", "/abs/path/Button.tsx"))
  end)

  it("does not match wrong extension", function()
    assert.is_false(glob.matches_section("*.tsx", "/abs/path/Button.ts"))
  end)

  it("supports comma-separated patterns — matches first", function()
    assert.is_true(glob.matches_section("*.tsx, *.jsx", "Button.tsx"))
  end)

  it("supports comma-separated patterns — matches second", function()
    assert.is_true(glob.matches_section("*.tsx, *.jsx", "Button.jsx"))
  end)

  it("trims whitespace around comma-separated patterns", function()
    assert.is_true(glob.matches_section("*.tsx ,  *.jsx", "Button.tsx"))
  end)

  it("returns false when no pattern matches", function()
    assert.is_false(glob.matches_section("*.py, *.rb", "Button.tsx"))
  end)

  it("matches use*.ts hook pattern", function()
    assert.is_true(glob.matches_section("use*.ts", "useAuth.ts"))
    assert.is_false(glob.matches_section("use*.ts", "authService.ts"))
  end)

  it("matches **/tests/** against path starting directly with tests/", function()
    assert.is_true(glob.matches_section("**/tests/**", "tests/bar.ts"))
    assert.is_true(glob.matches_section("**/tests/**", "src/foo/tests/bar.ts"))
  end)
end)
