local codex    = require("novibe.providers.codex")
local claude   = require("novibe.providers.claude")
local opencode = require("novibe.providers.opencode")
local gemini   = require("novibe.providers.gemini")

-- Minimal setup so codex.build_cmd can read config.options.system_prompt
require("novibe.config").setup({ system_prompt = "TEST_SYSTEM_PROMPT" })

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function make_stream(events)
  return table.concat(vim.tbl_map(vim.json.encode, events), "\n")
end

local THREAD_ID  = "019e0000-0000-7000-0000-000000000001"
local THREAD_ID2 = "019e0000-0000-7000-0000-000000000002"

local function agent_stream(text, thread_id)
  return make_stream({
    { type = "thread.started", thread_id = thread_id or THREAD_ID },
    { type = "turn.started" },
    { type = "item.completed", item = { id = "item_0", type = "agent_message", text = text } },
    { type = "turn.completed", usage = { input_tokens = 100, output_tokens = 20 } },
  })
end

local function agent_stream_with_cmd(text)
  return make_stream({
    { type = "thread.started", thread_id = THREAD_ID },
    { type = "turn.started" },
    { type = "item.started",   item = { id = "item_0", type = "command_execution", command = "ls" } },
    { type = "item.completed", item = { id = "item_0", type = "command_execution",
        command = "ls", aggregated_output = "file.lua\n", exit_code = 0, status = "completed" } },
    { type = "item.completed", item = { id = "item_1", type = "agent_message", text = text } },
    { type = "turn.completed", usage = { input_tokens = 200, cached_input_tokens = 50, output_tokens = 30 } },
  })
end

-- ---------------------------------------------------------------------------
-- codex.parse_chunk
-- ---------------------------------------------------------------------------

describe("codex.parse_chunk", function()
  it("always returns empty string (non-streaming provider)", function()
    assert.equals("", codex.parse_chunk("anything"))
    assert.equals("", codex.parse_chunk(""))
    assert.equals("", codex.parse_chunk('{"type":"item.completed"}'))
  end)
end)

-- ---------------------------------------------------------------------------
-- codex.parse_output — happy path
-- ---------------------------------------------------------------------------

describe("codex.parse_output — happy path", function()
  it("parses a valid JSON agent_message", function()
    local payload = vim.json.encode({ code = "return 1", message = nil, changes = {}, done = true })
    local resp, usage = codex.parse_output(agent_stream(payload))
    assert.equals("return 1", resp.code)
    assert.equals(true, resp.done)
    assert.is_nil(resp.message)
    assert.same({}, resp.changes)
  end)

  it("extracts thread_id as session_id", function()
    local payload = vim.json.encode({ code = "x", changes = {}, done = true })
    local _, usage = codex.parse_output(agent_stream(payload, THREAD_ID2))
    assert.equals(THREAD_ID2, usage.session_id)
  end)

  it("extracts input and output token counts", function()
    local payload = vim.json.encode({ code = "x", changes = {}, done = true })
    local _, usage = codex.parse_output(agent_stream(payload))
    assert.equals(100, usage.input_tokens)
    assert.equals(20,  usage.output_tokens)
  end)

  it("skips command_execution items and finds agent_message", function()
    local payload = vim.json.encode({ code = "skipped cmd", changes = {}, done = true })
    local resp, usage = codex.parse_output(agent_stream_with_cmd(payload))
    assert.equals("skipped cmd", resp.code)
    assert.equals(200, usage.input_tokens)
    assert.equals(30,  usage.output_tokens)
  end)

  it("returns last agent_message when multiple present", function()
    local first  = vim.json.encode({ code = "first",  changes = {}, done = false })
    local second = vim.json.encode({ code = "second", changes = {}, done = true  })
    local stdout = make_stream({
      { type = "thread.started", thread_id = THREAD_ID },
      { type = "turn.started" },
      { type = "item.completed", item = { id = "item_0", type = "agent_message", text = first  } },
      { type = "item.completed", item = { id = "item_1", type = "agent_message", text = second } },
      { type = "turn.completed", usage = { input_tokens = 10, output_tokens = 5 } },
    })
    local resp = codex.parse_output(stdout)
    assert.equals("second", resp.code)
  end)
end)

-- ---------------------------------------------------------------------------
-- codex.parse_output — markdown fence stripping
-- ---------------------------------------------------------------------------

describe("codex.parse_output — markdown fence stripping", function()
  it("strips ```json fences from the agent message", function()
    local inner   = vim.json.encode({ code = "fenced", changes = {}, done = true })
    local fenced  = "```json\n" .. inner .. "\n```"
    local resp    = codex.parse_output(agent_stream(fenced))
    assert.equals("fenced", resp.code)
  end)

  it("strips plain ``` fences", function()
    local inner  = vim.json.encode({ code = "plain", changes = {}, done = true })
    local fenced = "```\n" .. inner .. "\n```"
    local resp   = codex.parse_output(agent_stream(fenced))
    assert.equals("plain", resp.code)
  end)
end)

-- ---------------------------------------------------------------------------
-- codex.parse_output — fallback / error cases
-- ---------------------------------------------------------------------------

describe("codex.parse_output — fallback cases", function()
  it("falls back to raw text when agent_message is not valid JSON", function()
    local resp = codex.parse_output(agent_stream("not json at all"))
    assert.equals("not json at all", resp.code)
    assert.same({}, resp.changes)
    assert.equals(true, resp.done)
  end)

  it("returns error message when no agent_message event present", function()
    local stdout = make_stream({
      { type = "thread.started", thread_id = THREAD_ID },
      { type = "turn.started" },
      { type = "turn.completed", usage = { input_tokens = 5, output_tokens = 0 } },
    })
    local resp, usage = codex.parse_output(stdout)
    assert.equals("", resp.code)
    assert.truthy(resp.message)  -- error message set
    assert.equals(THREAD_ID, usage.session_id)
  end)

  it("handles empty stdout gracefully", function()
    local resp, usage = codex.parse_output("")
    assert.equals("", resp.code)
    assert.is_nil(usage.session_id)
    assert.is_nil(usage.input_tokens)
  end)

  it("ignores malformed JSON lines without crashing", function()
    local payload = vim.json.encode({ code = "ok", changes = {}, done = true })
    local stdout  = "not-json\n" .. agent_stream(payload)
    local resp    = codex.parse_output(stdout)
    assert.equals("ok", resp.code)
  end)
end)

-- ---------------------------------------------------------------------------
-- codex.build_cmd — fresh session
-- ---------------------------------------------------------------------------

describe("codex.build_cmd — fresh session", function()
  it("starts with codex exec --json --sandbox read-only", function()
    local cmd = codex.build_cmd("/usr/bin/codex", "hello", { profile = nil, session_id = nil })
    assert.equals("/usr/bin/codex", cmd[1])
    assert.equals("exec",           cmd[2])
    assert.equals("--json",         cmd[3])
    assert.equals("--sandbox",      cmd[4])
    assert.equals("read-only",      cmd[5])
  end)

  it("includes -c instructions argument", function()
    local cmd = codex.build_cmd("/usr/bin/codex", "hello", { profile = nil, session_id = nil })
    local found = false
    for _, v in ipairs(cmd) do
      if v == "-c" then found = true; break end
    end
    assert.is_true(found)
  end)

  it("instructions value contains the system prompt", function()
    local cmd = codex.build_cmd("/usr/bin/codex", "hello", { profile = nil, session_id = nil })
    local after_c = false
    for _, v in ipairs(cmd) do
      if after_c then
        assert.truthy(v:find("TEST_SYSTEM_PROMPT", 1, true))
        break
      end
      if v == "-c" then after_c = true end
    end
  end)

  it("prompt is the last argument", function()
    local cmd = codex.build_cmd("/usr/bin/codex", "my prompt", { profile = nil, session_id = nil })
    assert.equals("my prompt", cmd[#cmd])
  end)

  it("adds -m when profile.model is set", function()
    local cmd = codex.build_cmd("/usr/bin/codex", "p", { profile = { model = "o4-mini" }, session_id = nil })
    local found = false
    for i, v in ipairs(cmd) do
      if v == "-m" and cmd[i + 1] == "o4-mini" then found = true; break end
    end
    assert.is_true(found)
  end)

  it("does not add -m when no profile", function()
    local cmd = codex.build_cmd("/usr/bin/codex", "p", { profile = nil, session_id = nil })
    for _, v in ipairs(cmd) do
      assert.not_equals("-m", v)
    end
  end)

  it("ignores profile.effort (no codex equivalent)", function()
    local cmd = codex.build_cmd("/usr/bin/codex", "p",
      { profile = { model = "o3", effort = "high" }, session_id = nil })
    for _, v in ipairs(cmd) do
      assert.not_equals("--effort",  v)
      assert.not_equals("--variant", v)
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- codex.build_cmd — resume session
-- ---------------------------------------------------------------------------

describe("codex.build_cmd — resume session", function()
  it("uses exec resume <thread_id> when session_id is set", function()
    local cmd = codex.build_cmd("/usr/bin/codex", "follow-up",
      { profile = nil, session_id = THREAD_ID })
    assert.equals("/usr/bin/codex", cmd[1])
    assert.equals("exec",           cmd[2])
    assert.equals("resume",         cmd[3])
    assert.equals(THREAD_ID,        cmd[4])
    assert.equals("--json",         cmd[5])
  end)

  it("does not include --sandbox on resume", function()
    local cmd = codex.build_cmd("/usr/bin/codex", "p", { profile = nil, session_id = THREAD_ID })
    for _, v in ipairs(cmd) do
      assert.not_equals("--sandbox", v)
    end
  end)

  it("uses fresh exec when session_id is empty string", function()
    local cmd = codex.build_cmd("/usr/bin/codex", "p", { profile = nil, session_id = "" })
    assert.equals("exec", cmd[2])
    assert.not_equals("resume", cmd[3])
  end)

  it("still adds -m on resume when profile.model is set", function()
    local cmd = codex.build_cmd("/usr/bin/codex", "p",
      { profile = { model = "o3" }, session_id = THREAD_ID })
    local found = false
    for i, v in ipairs(cmd) do
      if v == "-m" and cmd[i + 1] == "o3" then found = true; break end
    end
    assert.is_true(found)
  end)
end)

-- ---------------------------------------------------------------------------
-- Provider registration — all four providers discoverable
-- ---------------------------------------------------------------------------

describe("providers.get", function()
  local providers = require("novibe.providers")

  it("returns claude provider by default", function()
    assert.equals("claude", providers.get(nil).name)
    assert.equals("claude", providers.get("claude").name)
  end)

  it("returns opencode provider", function()
    assert.equals("opencode", providers.get("opencode").name)
  end)

  it("returns gemini provider", function()
    assert.equals("gemini", providers.get("gemini").name)
  end)

  it("returns codex provider", function()
    assert.equals("codex", providers.get("codex").name)
  end)

  it("falls back to claude for unknown provider name", function()
    assert.equals("claude", providers.get("unknown").name)
  end)

  it("all providers expose required interface", function()
    for _, name in ipairs({ "claude", "opencode", "gemini", "codex" }) do
      local p = providers.get(name)
      assert.is_function(p.find_bin,     name .. " missing find_bin")
      assert.is_function(p.build_cmd,    name .. " missing build_cmd")
      assert.is_function(p.parse_output, name .. " missing parse_output")
      assert.is_function(p.parse_chunk,  name .. " missing parse_chunk")
      assert.not_nil(p.streaming,        name .. " missing streaming flag")
    end
  end)

  it("codex is non-streaming", function()
    assert.is_false(codex.streaming)
  end)

  it("claude, opencode, gemini are streaming", function()
    assert.is_true(claude.streaming)
    assert.is_true(opencode.streaming)
    assert.is_true(gemini.streaming)
  end)
end)
