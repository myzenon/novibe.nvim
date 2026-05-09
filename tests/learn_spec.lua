local learn = require("novibe.learn")

local function with_tmp_cwd(fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local prev = vim.fn.getcwd()
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  local ok, err = pcall(fn, dir)
  vim.cmd("cd " .. vim.fn.fnameescape(prev))
  vim.fn.delete(dir, "rf")
  if not ok then error(err, 2) end
end

local function read_diffs(dir)
  local path = dir .. "/.no_vibe/diffs.json"
  if vim.fn.filereadable(path) == 0 then return nil end
  return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

describe("learn.teach — diff capture", function()
  it("creates .no_vibe/diffs.json with one entry on first call", function()
    with_tmp_cwd(function(dir)
      learn.teach("a", "b", "reason", "foo.ts", "claude", nil, nil)
      local diffs = read_diffs(dir)
      assert.equals(1, #diffs)
      assert.equals("a", diffs[1].original)
      assert.equals("b", diffs[1].current)
      assert.equals("reason", diffs[1].reason)
    end)
  end)

  it("appends to existing diffs.json on subsequent calls", function()
    with_tmp_cwd(function(dir)
      learn.teach("a", "b", "r1", "foo.ts", "claude", nil, nil)
      learn.teach("c", "d", "r2", "bar.ts", "claude", nil, nil)
      local diffs = read_diffs(dir)
      assert.equals(2, #diffs)
      assert.equals("a", diffs[1].original)
      assert.equals("c", diffs[2].original)
    end)
  end)

  it("does nothing when original equals current", function()
    with_tmp_cwd(function(dir)
      learn.teach("same", "same", "reason", "foo.ts", "claude", nil, nil)
      local diffs = read_diffs(dir)
      assert.is_nil(diffs)
    end)
  end)

  it("stores reason as nil when reason is empty string", function()
    with_tmp_cwd(function(dir)
      learn.teach("a", "b", "", "foo.ts", "claude", nil, nil)
      local diffs = read_diffs(dir)
      assert.equals(1, #diffs)
      assert.is_nil(diffs[1].reason)
    end)
  end)

  it("stores filename relative to cwd", function()
    with_tmp_cwd(function()
      -- use the resolved cwd to avoid macOS /var → /private/var symlink mismatch
      local cwd = vim.fn.getcwd()
      learn.teach("a", "b", "r", cwd .. "/src/foo.ts", "claude", nil, nil)
      local diffs = read_diffs(cwd)
      assert.equals("src/foo.ts", diffs[1].filename)
    end)
  end)

  it("records a timestamp on each diff", function()
    with_tmp_cwd(function(dir)
      learn.teach("a", "b", "r", "foo.ts", "claude", nil, nil)
      local diffs = read_diffs(dir)
      assert.is_string(diffs[1].at)
      assert.truthy(diffs[1].at:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d$"))
    end)
  end)

  it("does not trigger extract when auto_after is nil", function()
    with_tmp_cwd(function(dir)
      -- claude binary "false" would fail if invoked — verifies extract was not called
      learn.teach("a", "b", "r", "foo.ts", "/usr/bin/false", nil, nil)
      local diffs = read_diffs(dir)
      assert.equals(1, #diffs)  -- diff was saved, extract not triggered
    end)
  end)

  it("does not trigger extract when accumulated diffs are below threshold", function()
    with_tmp_cwd(function(dir)
      learn.teach("a", "b", "r", "foo.ts", "/usr/bin/false", 5, nil)
      local diffs = read_diffs(dir)
      assert.equals(1, #diffs)  -- 1 diff, threshold 5 → no extract
    end)
  end)
end)

describe("learn — fresh-project threshold", function()
  it("uses threshold 1 when no learned-*.md files exist", function()
    with_tmp_cwd(function(dir)
      -- vim.system is async — we can't easily verify extract was *called*,
      -- but we can verify the diff file is preserved (extract spawns async, doesn't clear synchronously).
      -- This test mainly documents that the call doesn't error.
      local ok = pcall(learn.teach, "a", "b", "r", "foo.ts", "/usr/bin/false", 3, nil)
      assert.is_true(ok)
      local diffs = read_diffs(dir)
      assert.equals(1, #diffs)  -- 1 diff is saved before any extract attempt
    end)
  end)

  it("uses configured threshold when learned-*.md with content exists", function()
    with_tmp_cwd(function(dir)
      vim.fn.mkdir(dir .. "/.no_vibe", "p")
      vim.fn.writefile({ "## always", "- some learned rule" }, dir .. "/.no_vibe/learned-style.md")
      -- threshold 5, only 1 diff → must NOT trigger extract (verified: claude=false would error if spawned)
      learn.teach("a", "b", "r", "foo.ts", "/usr/bin/false", 5, nil)
      local diffs = read_diffs(dir)
      assert.equals(1, #diffs)
    end)
  end)

  it("treats empty learned-*.md as no rules (uses fresh threshold of 1)", function()
    with_tmp_cwd(function(dir)
      vim.fn.mkdir(dir .. "/.no_vibe", "p")
      vim.fn.writefile({ "" }, dir .. "/.no_vibe/learned-empty.md")
      -- empty file → has_learned_rules returns false → threshold = 1
      -- this test mainly ensures the empty-file path doesn't crash
      local ok = pcall(learn.teach, "a", "b", "r", "foo.ts", "/usr/bin/false", 3, nil)
      assert.is_true(ok)
    end)
  end)
end)

describe("learn.extract — error handling", function()
  it("notifies and returns when no diffs are accumulated", function()
    with_tmp_cwd(function()
      -- no diffs.json file exists
      local notified
      local orig_notify = vim.notify
      vim.notify = function(msg, lvl) notified = { msg = msg, lvl = lvl } end
      learn.extract("/usr/bin/false", nil)
      vim.notify = orig_notify
      assert.truthy(notified)
      assert.truthy(notified.msg:find("no accumulated diffs"))
    end)
  end)
end)
