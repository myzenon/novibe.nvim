local stream = require("novibe.stream")

describe("stream.extract_code", function()
  it("returns nil before the code field starts", function()
    assert.is_nil(stream.extract_code(''))
    assert.is_nil(stream.extract_code('{"message":"hi"'))
    assert.is_nil(stream.extract_code('{"co'))
  end)

  it("returns nil while the opening quote has no body yet", function()
    assert.is_nil(stream.extract_code('{"code":""'))
    assert.is_nil(stream.extract_code('{"code": "'))
  end)

  it("extracts a simple complete value", function()
    assert.equals("hello", stream.extract_code('{"code":"hello"'))
  end)

  it("extracts a partial unterminated value", function()
    assert.equals("partial impl", stream.extract_code('{"code":"partial impl'))
  end)

  it("decodes JSON escape sequences", function()
    assert.equals('a "quoted" b',  stream.extract_code('{"code":"a \\"quoted\\" b"'))
    assert.equals("line1\nline2",  stream.extract_code('{"code":"line1\\nline2"'))
    assert.equals("tab\there",     stream.extract_code('{"code":"tab\\there"'))
    assert.equals('back\\slash',   stream.extract_code('{"code":"back\\\\slash"'))
    assert.equals("a/b",           stream.extract_code('{"code":"a\\/b"'))
  end)

  it("decodes \\uXXXX escapes", function()
    -- U+00E9 = é
    assert.equals("caf\u{00E9}", stream.extract_code('{"code":"caf\\u00e9"'))
  end)

  it("tolerates whitespace around the colon", function()
    assert.equals("ok", stream.extract_code('{"code"   :   "ok"'))
  end)

  it("stops at the closing quote", function()
    assert.equals("first", stream.extract_code('{"code":"first","message":"second"}'))
  end)
end)
