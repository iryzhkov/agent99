-- Configuration: defaults, provider presets, validation, and the state-dir
-- paths every other module shares. `setup(opts)` merges user options over
-- the defaults and resolves the provider; the result lives in M.options.

local M = {}

-- Built-in provider presets. A provider is either the name of a preset
-- ("deepseek"), or a table { preset = "deepseek", model = "...", ... } whose
-- fields override the preset, or a full table with no preset at all.
--
-- kind = "openai": any OpenAI-compatible chat-completions API, driven by the
--   bridge's own function-calling loop. This is the full-featured path
--   (chat panel, follow-ups, streaming).
-- kind = "claude": spawns `claude -p` with the LSP tools attached over MCP.
--   Uses your Claude subscription/API quota; no follow-ups or chat.
M.presets = {
    deepseek = {
        kind = "openai",
        base_url = "https://api.deepseek.com/v1",
        model = "deepseek-chat",
        api_key_env = "DEEPSEEK_API_KEY",
        keyring_service = "deepseek",
    },
    openai = {
        kind = "openai",
        base_url = "https://api.openai.com/v1",
        model = "gpt-4o-mini",
        api_key_env = "OPENAI_API_KEY",
        keyring_service = "openai",
    },
    openrouter = {
        kind = "openai",
        base_url = "https://openrouter.ai/api/v1",
        model = "deepseek/deepseek-chat",
        api_key_env = "OPENROUTER_API_KEY",
        keyring_service = "openrouter",
    },
    -- Local models need no key; api_key is sent as a dummy bearer token.
    ollama = {
        kind = "openai",
        base_url = "http://localhost:11434/v1",
        model = "qwen2.5-coder:14b",
        api_key = "ollama",
    },
    claude = {
        kind = "claude",
        claude_cmd = "claude",
        allowed_tools = { "mcp__lsp", "Read", "Grep", "Glob" },
    },
}

local provider_defaults = {
    -- Sampling and loop limits, passed through to the bridge.
    temperature = 0.0,
    max_tokens = nil,  -- nil: the API's default
    max_rounds = 30,
    -- Advertise the full tool roster (type_definition, implementation, call
    -- hierarchy, document_symbols, expand_symbol) instead of the slim
    -- default. Costs ~1k extra prompt tokens per round.
    full_tools = false,
}

M.defaults = {
    provider = "deepseek",
    -- Additional presets, merged over M.presets: providers = { mylab = {...} }
    -- makes provider = "mylab" resolvable.
    providers = {},
    -- Preset name the chat panel uses when the main provider cannot chat
    -- (the claude provider returns no transcript, so the panel needs an
    -- openai-kind provider). nil: the panel refuses with a hint instead.
    chat_provider = nil,

    -- Show the proposed replacement in a preview split (<CR> apply, q
    -- discard) instead of editing the buffer directly.
    preview = true,
    -- After applying, wait auto_fix_delay_ms for the LSP to re-publish and,
    -- if the edit introduced new ERROR diagnostics, automatically ask the
    -- agent (with its full conversation) to fix them. One round, no loops.
    auto_fix = true,
    auto_fix_delay_ms = 2000,
    -- File context embedded in the initial prompt: the whole file when it
    -- has at most context_full_file_max lines, otherwise context_lines
    -- around the selection.
    context_full_file_max = 200,
    context_lines = 50,
    timeout_ms = 5 * 60 * 1000,
    -- <leader>9v stages selections in "auto" mode: the model itself decides
    -- whether the instruction is an edit or a question, from the reply's
    -- shape (no extra classification call). gm in compose hardcodes the
    -- mode (cycles auto/edit/ask); false restores 9v = always edit.
    auto_mode = true,

    history = {
        -- Request records kept on disk under stdpath("state")/agent99.
        keep = 100,
    },
    -- What a symbol edit tool reports back after applying: it waits for the
    -- language servers to re-publish (up to post_edit.wait_ms, returning as
    -- soon as they settle) and lists only the errors/warnings the edit
    -- introduced, with counts for what was already there and what it fixed.
    post_edit = {
        wait_ms = 4000,
        -- After a symbol edit, format the edited region through the server
        -- ("range"; servers without range formatting, gopls among them,
        -- format the whole file only when it is a Go file) and run the
        -- server's organize-imports action, so a new call to a package the
        -- file does not import yet costs the agent no extra round.
        format = "range",
        organize_imports = true,
        -- Run a linter as well and include its output. Commands per
        -- filetype, with {file}, {dir} and {root} expanded, e.g.
        --   commands = { python = "ruff check {file}", go = "go vet {dir}" }
        commands = {},
        -- With nvim-lint installed and configured for the filetype, run its
        -- linters too; their findings land in the same diagnostics report.
        nvim_lint = true,
        lint_timeout_ms = 30000,
        -- Project-wide check run by the check_project tool (cwd = root),
        -- e.g. "go vet ./..." or "npx tsc --noEmit". nil: guessed from the
        -- project's marker files (go.mod, Cargo.toml, tsconfig.json, ...).
        check = nil,
        check_timeout_ms = 5 * 60 * 1000,
    },

    ui = {
        width = 0.4,      -- fraction of columns for the agent panel
        input_height = 5, -- prompt pane height in lines
        -- Layout of the record view (history <CR>, ask answers).
        record = {
            content_width = 120, -- columns for the content pane, so code up
                                 -- to that width renders without wrapping
            list_width = 26,     -- section list columns
            border = "rounded",
        },
        -- Layout of the compose picker (<leader>9v / 9a).
        compose = {
            width = 170,          -- max total columns (clamped to the screen)
            height = 24,          -- max total rows
            preview_ratio = 0.7,  -- fraction of the width given to the preview
                                  -- (the prompt column keeps at least 36 cols)
            prompt_height = 5,    -- instruction pane rows
            border = "rounded",
        },
    },

    -- false disables all keymaps; true uses these defaults; a table merges
    -- over them (set a key to false to drop that one mapping).
    keymaps = {
        auto = "<leader>99",            -- x: compose - the model infers edit/ask
        compose = "<leader>99",         -- n: reopen the compose draft
        edit = "<leader>9e",            -- x: compose, hardcoded edit
        ask = "<leader>9a",             -- x: compose, hardcoded ask
        chat = "<leader>9c",            -- n: toggle the chat panel
        chat_selection = "<leader>9c",  -- x: panel with selection as context
        followup = "<leader>9f",        -- n: follow up on last edit/answer
        cancel = "<leader>9x",          -- n: cancel request / discard preview
        history = "<leader>9h",         -- n: request history
        record = "<leader>9r",          -- n: re-open the last record view
        logs = "<leader>9l",            -- n: view logs
    },

    -- Path to the compiled bridge binary; nil means <plugin>/bin/agent99-bridge
    -- (built with `make build`, requires Go).
    bridge_bin = nil,
}

M.options = vim.deepcopy(M.defaults)

local function resolve_provider(spec, extra_presets)
    local presets = vim.tbl_extend("force", M.presets, extra_presets or {})
    local base, overrides
    if type(spec) == "string" then
        base = presets[spec]
        if not base then
            error(("agent99: unknown provider preset %q (known: %s)"):format(
                spec, table.concat(vim.tbl_keys(presets), ", ")), 0)
        end
        overrides = {}
    elseif type(spec) == "table" then
        if spec.preset then
            base = presets[spec.preset]
            if not base then
                error(("agent99: unknown provider preset %q"):format(spec.preset), 0)
            end
        else
            base = {}
        end
        overrides = spec
    else
        error("agent99: provider must be a preset name or a table", 0)
    end
    local p = vim.tbl_deep_extend("force", provider_defaults, base, overrides)
    p.preset = nil
    p.kind = p.kind or "openai"
    if p.kind ~= "openai" and p.kind ~= "claude" then
        error(("agent99: unknown provider kind %q (openai or claude)"):format(p.kind), 0)
    end
    if p.kind == "openai" and not p.base_url then
        error("agent99: an openai-kind provider needs base_url", 0)
    end
    return p
end

--- Merge user options over the defaults and resolve the provider table.
function M.setup(opts)
    opts = opts or {}
    local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
    -- keymaps: true means defaults; a table was already merged over the
    -- default table by tbl_deep_extend; false stays false.
    if merged.keymaps == true then
        merged.keymaps = vim.deepcopy(M.defaults.keymaps)
    end
    merged.provider = resolve_provider(opts.provider or M.defaults.provider,
        merged.providers)
    M.options = merged
    return merged
end

--- Resolve a preset name to a full provider table without changing the
--- active provider (used by the chat panel's chat_provider fallback).
function M.resolve(name)
    return resolve_provider(name, M.options.providers)
end

--- Switch the active provider at runtime (:Agent99Provider). `name` is a
--- preset name - built-in or from options.providers. Requests already
--- running are unaffected; the next request uses the new provider.
function M.switch_provider(name)
    M.options.provider = resolve_provider(name, M.options.providers)
    return M.options.provider
end

--- Preset names available for switching (built-ins + user-defined).
function M.provider_names()
    local names = {}
    for name in pairs(vim.tbl_extend("force", M.presets, M.options.providers or {})) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

--- One-line human description of the active provider.
function M.provider_label()
    local p = M.options.provider
    if p.kind == "claude" then
        return ("claude (%s)"):format(p.model or "CLI default model")
    end
    return ("%s @ %s"):format(tostring(p.model), tostring(p.base_url))
end

-- ------------------------------------------------------------------ paths --

function M.state_dir()
    local dir = vim.fn.stdpath("state") .. "/agent99"
    vim.fn.mkdir(dir .. "/history", "p")
    return dir
end

function M.history_dir()
    return M.state_dir() .. "/history"
end

function M.log_path()
    return M.state_dir() .. "/agent99.log"
end

function M.plugin_root()
    local src = debug.getinfo(1, "S").source:sub(2)
    return vim.fn.fnamemodify(src, ":h:h:h")
end

function M.bridge_bin()
    return M.options.bridge_bin or (M.plugin_root() .. "/bin/agent99-bridge")
end

-- -------------------------------------------------------------------- log --

function M.log(lines)
    local f = io.open(M.log_path(), "a")
    if not f then return end
    f:write(("\n=== %s ===\n"):format(os.date("%Y-%m-%d %H:%M:%S")))
    f:write(type(lines) == "table" and table.concat(lines, "\n") or tostring(lines))
    f:write("\n")
    f:close()
end

-- ---------------------------------------------------------------- api key --

--- Resolve a provider's API key (the active one unless `provider` is
--- given): a literal api_key wins, then the environment variable, then the
--- system keyring (secret-tool/libsecret). Returns nil when nothing
--- resolves.
function M.resolve_api_key(provider)
    local p = provider or M.options.provider
    if p.api_key and p.api_key ~= "" then
        return p.api_key
    end
    if p.api_key_env then
        local key = vim.env[p.api_key_env]
        if key and key ~= "" then
            return key
        end
    end
    if p.keyring_service and vim.fn.executable("secret-tool") == 1 then
        local out = vim.fn.system({ "secret-tool", "lookup", "service", p.keyring_service })
        if vim.v.shell_error == 0 and out ~= "" then
            return (out:gsub("%s+$", ""))
        end
    end
    return nil
end

--- Prompt for the API key and store it in the system keyring, so requests
--- work without exporting the environment variable.
function M.set_key()
    local p = M.options.provider
    if not p.keyring_service then
        vim.notify("agent99: provider.keyring_service is not configured", vim.log.levels.ERROR)
        return
    end
    if vim.fn.executable("secret-tool") ~= 1 then
        vim.notify("agent99: secret-tool not found (install libsecret)", vim.log.levels.ERROR)
        return
    end
    local key = vim.fn.inputsecret(("API key for %s: "):format(p.base_url or p.keyring_service))
    if key == nil or key == "" then
        return
    end
    local res = vim.system({
        "secret-tool", "store", "--label", "agent99 " .. p.keyring_service,
        "service", p.keyring_service,
    }, { stdin = key }):wait()
    if res.code == 0 then
        vim.notify(("agent99: key stored in keyring (service=%s)"):format(p.keyring_service))
    else
        vim.notify("agent99: storing the key failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
    end
end

return M
