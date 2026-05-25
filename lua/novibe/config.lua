local M = {}

---@class novibe.Profile
---@field label string Display name shown in :NovibeProfile picker
---@field provider? "claude"|"opencode"|"gemini"|"codex" CLI provider; defaults to "claude"
---@field model? string Model identifier (claude alias like "haiku" or full ID; opencode uses "provider/model" format)
---@field effort? "minimal"|"low"|"medium"|"high"|"xhigh"|"max" Reasoning effort (claude --effort / opencode --variant / codex model_reasoning_effort; ignored by gemini; "minimal" is codex-only)
---@field file_context? boolean Inject sibling files + parsed imports into the prompt for better grounding. Recommended for cheaper / less reliable models. Defaults to false.

---@class novibe.LearnConfig
---@field auto_extract_after? integer Number of #teach diffs that triggers auto-distillation (default 3; nil disables)

---@class novibe.Config
---@field bare? boolean Use --bare flag (claude only; requires ANTHROPIC_API_KEY auth)
---@field profiles? novibe.Profile[] Profiles selectable via :NovibeProfile
---@field learn? novibe.LearnConfig
---@field system_prompt? string Override default system prompt
---@field keymap? string Visual-mode keymap for :NovibeAct (defaults to none — bind via lazy.nvim keys spec)

M.defaults = {
  keymap = nil,
  bare = false,  -- set true only if you auth via ANTHROPIC_API_KEY, not claude login
  active_profile = nil,
  active_consult_profile = nil,
  profiles = {},
  learn = {
    auto_extract_after = 3,  -- nil to disable auto-extraction
  },
  act2 = {
    -- Keys are buffer-local and only fire when the cursor is inside the active scope.
    -- Override in setup() if any default conflicts with your vim bindings.
    keys = {
      accept   = "<CR>",       -- splice AI code, show out-of-scope scratch
      undo     = "U",          -- restore original lines and dismiss (or cancel teach)
      reprompt = "<leader>r",  -- restore original and re-open input float pre-filled
      teach    = "<leader>t",  -- accept + enter teach mode (press again when done editing)
    },
  },
  system_prompt = [[
You are a code implementation assistant embedded in a Neovim plugin.
You receive a code selection from a file and an instruction. You must ALWAYS respond with a single JSON object — no markdown, no prose, nothing outside the JSON.

Schema:
{
  "code": string,         // the modified selection ONLY — spliced directly in place
  "message": string|null, // question, explanation, or proposal summary shown to the user
  "changes": [            // out-of-scope changes needed in other parts of the file or other files
    {
      "file": string,         // relative path from project root
      "description": string,  // human-readable summary of the change
      "action": string,       // "replace" | "insert_after" | "insert_before" | "delete"
      "find": string,         // exact existing code block to locate (anchor for all actions except "delete")
      "replace": string       // for "replace": new code; for "insert_after"/"insert_before": code to insert; empty for "delete"
    }
  ],
  "done": boolean         // true = apply all changes now and close, false = wait for user reply
}

Rules:
- "code" contains ONLY the lines that were in the selection, modified as requested. Never include lines from outside the selection.
- If the change requires modifications outside the selection (imports, types, other files), put them in "changes". Never include them in "code".
- For "changes" entries: use "replace" when modifying existing code, "insert_after" when adding new code after an anchor, "insert_before" when adding before. "find" must always be an existing block verbatim from the file. Use "delete" to remove an entire file — set "find" and "replace" to empty strings.
- CRITICAL: every "file" path in "changes" MUST reference a file that already exists in the project. Do NOT invent file paths. Do NOT split inline code into a new file unless the user explicitly asks. If you want to add new code (helper, sub-component, type), put it in the file the user is currently editing.
- If a "Project files" list is provided in the prompt, only reference paths from that list.
- Set "done": false if you have a question or want the user to review changes before applying.
- Set "done": true when the user has confirmed and changes are ready to apply, or when no out-of-scope changes are needed.
- If there are no out-of-scope changes and no message, set "changes": [], "message": null, "done": true.
- Preserve indentation and formatting of the original selection in "code".
- In subsequent turns the user may reply in plain text — respond with the same JSON schema (omit "code" after the first turn).
]],
}

M.options = vim.deepcopy(M.defaults)

local state_path = vim.fn.stdpath("data") .. "/novibe/state.json"

function M.save_state()
  local state = {}
  if M.options.active_profile then
    state.active_profile_label = M.options.active_profile.label
  end
  if M.options.active_consult_profile then
    state.active_consult_profile_label = M.options.active_consult_profile.label
  end
  vim.fn.mkdir(vim.fn.fnamemodify(state_path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(state) }, state_path)
end

function M.load_state()
  if vim.fn.filereadable(state_path) == 0 then return end
  local lines = vim.fn.readfile(state_path)
  if #lines == 0 then return end
  local ok, state = pcall(vim.json.decode, lines[1])
  if not ok or type(state) ~= "table" then return end
  local profiles = M.options.profiles or {}
  for _, p in ipairs(profiles) do
    if state.active_profile_label and p.label == state.active_profile_label then
      M.options.active_profile = p
    end
    if state.active_consult_profile_label and p.label == state.active_consult_profile_label then
      M.options.active_consult_profile = p
    end
  end
end

---@param opts? novibe.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
  M.load_state()
end

return M
