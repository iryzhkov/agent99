-- Prompt construction: the tool guide, the replacement contract, and the
-- builders for edit / ask / follow-up / chat prompts. Pure functions of the
-- buffer and config — no request state.

local config = require("agent99.config")

local M = {}

local TOOL_GUIDE = {
    "You have %s tools backed by the user's live editor.",
    "Explore cheaply, from coarse to fine: workspace_map (whole-repo shape -",
    "files and top-level declarations in one call; the first move in an",
    "unfamiliar repo), skim (nested structure of specific files), find_symbol",
    "(fetch exactly one function/class by name with include_body=true -",
    "prefer this over reading files), ts_query (structural multi-file",
    "search), plus grep (hits are annotated with their enclosing",
    "[Symbol/Path]) and file reading. Semantic questions: references (each",
    "hit shows its enclosing symbol), hover, definition, workspace_symbols,",
    "diagnostics. buffer_lines shows a file's unsaved editor state; prefer",
    "it over disk reads for files the user has open.",
    "Rounds are the main cost: batch independent tool calls in a single",
    "turn. But keep grep TARGETED (specific pattern, plus path or glob):",
    "repo-wide greps return large annotated output that stays in your",
    "context for the rest of the run - map or skim first, then grep",
    "narrowly.",
    "Editing: the user's selection is your main context and the PRIMARY edit",
    "target - change it via the <replacement> reply. For changes that belong",
    "elsewhere (helpers, imports, other symbols or files), use",
    "replace_symbol_body / replace_symbol_lines (a slice of a symbol by",
    "symbol-relative line numbers - cheapest for small changes in big",
    "functions) / insert_after_symbol / insert_before_symbol, which address",
    "code by symbol name, apply immediately to editor buffers, and return",
    "fresh diagnostics so you see breakage at once.",
    "When a diagnostic lists quick_fixes, apply the language server's own fix",
    "via code_actions + apply_code_action instead of writing it yourself.",
    "Never use the symbol edit tools on the selected region itself: the",
    "selection is changed only through your <replacement> reply.",
    "code_actions/apply_code_action apply the editor's own quick fixes.",
}

M.CHAT_SYSTEM = table.concat({
    "You are an AI pair programmer living inside the user's Neovim session,",
    "conversing in a side panel. You explore the project with your tools and",
    "make code changes with the symbol edit tools (replace_symbol_body,",
    "replace_symbol_lines, insert_after_symbol, insert_before_symbol) and",
    "apply_code_action - edits apply to the user's editor buffers immediately",
    "and are shown to them as they happen, so never print whole files or",
    "large code blocks into the conversation; make the edit instead and",
    "mention it briefly. Check the diagnostics each edit returns. Answer in",
    "concise markdown, cite locations as file:line, and ask a short question",
    "when the request is ambiguous rather than guessing.",
}, "\n")

M.REPLACEMENT_REMINDER =
    "Remember: the replacement text MUST be wrapped in <replacement></replacement> tags."
M.MARKDOWN_REMINDER = "Answer in markdown."

local function replacement_contract(first, last)
    return {
        ("In your final reply, provide the replacement text for lines %d-%d"):format(first, last),
        "wrapped in <replacement></replacement> tags: raw code exactly as it",
        "should appear in the file - no markdown fences, no line numbers. Match",
        "the file's existing indentation style. Everything between the tags",
        "replaces those lines verbatim; everything outside the tags is discarded.",
        "Exception: if you made every needed change with the symbol edit tools",
        "and the selected lines themselves must stay as they are, reply instead",
        "with <summary>one short paragraph of what you changed and where</summary>.",
    }
end

-- Line-numbered snapshot of the file around the selection, embedded in the
-- prompt so the agent doesn't have to spend its first round on buffer_lines.
local function build_context(buf, first, last)
    local opts = config.options
    local total = vim.api.nvim_buf_line_count(buf)
    local cfirst, clast
    if total <= opts.context_full_file_max then
        cfirst, clast = 1, total
    else
        cfirst = math.max(1, first - opts.context_lines)
        clast = math.min(total, last + opts.context_lines)
    end
    local lines = vim.api.nvim_buf_get_lines(buf, cfirst - 1, clast, false)
    local numbered = {}
    for i, l in ipairs(lines) do
        numbered[i] = ("%d: %s"):format(cfirst + i - 1, l)
    end
    local label
    if cfirst == 1 and clast == total then
        label = ("Full content of the target file (%d lines, numbered) at request time:")
            :format(total)
    else
        label = ("Lines %d-%d of the target file (of %d total, numbered) at request time:")
            :format(cfirst, clast, total)
    end
    return table.concat({
        label,
        "<file_context>",
        table.concat(numbered, "\n"),
        "</file_context>",
        "This is a snapshot; buffer_lines gives the live state if you need to re-check.",
    }, "\n")
end

local function tool_prefix()
    return config.options.provider.kind == "claude" and "MCP (mcp__lsp__*)" or "LSP"
end

function M.edit(buf, file, ft, root, first, last, selection, instruction)
    local parts = {
        "You are performing a surgical code edit inside the user's Neovim session.",
        ("Target file: %s (filetype: %s)"):format(file, ft),
        ("Project root: %s"):format(root),
        ("The user selected lines %d-%d of the target file:"):format(first, last),
        "<selection>",
        selection,
        "</selection>",
        "The user's instruction for this selection:",
        "<instruction>",
        instruction,
        "</instruction>",
        "",
        build_context(buf, first, last),
        "",
        table.concat(TOOL_GUIDE, "\n"):format(tool_prefix()),
        "",
    }
    vim.list_extend(parts, replacement_contract(first, last))
    return table.concat(parts, "\n")
end

function M.ask(buf, file, ft, root, first, last, selection, question)
    local parts = {
        "You are answering a question about code inside the user's Neovim session.",
        ("Target file: %s (filetype: %s)"):format(file, ft),
        ("Project root: %s"):format(root),
        ("The user selected lines %d-%d of the target file:"):format(first, last),
        "<selection>",
        selection,
        "</selection>",
        "The user's question about this code:",
        "<question>",
        question,
        "</question>",
        "",
        build_context(buf, first, last),
        "",
        table.concat(TOOL_GUIDE, "\n"):format(tool_prefix()),
        "",
        "Answer the question directly and concisely, in markdown. Ground your",
        "answer in code you actually inspected and cite locations as file:line.",
        "Do NOT output <replacement> tags and do not edit anything - this is a",
        "question, not an edit request. The user may follow up afterwards to",
        "turn the discussion into an edit.",
    }
    return table.concat(parts, "\n")
end

function M.followup(file, first, last, region, instruction)
    local parts = {
        "Follow-up on the work above. The relevant region of " .. file,
        ("is now lines %d-%d and currently reads:"):format(first, last),
        "<current>",
        region,
        "</current>",
        "The user's follow-up instruction:",
        "<instruction>",
        instruction,
        "</instruction>",
        "",
    }
    vim.list_extend(parts, replacement_contract(first, last))
    return table.concat(parts, "\n")
end

return M
