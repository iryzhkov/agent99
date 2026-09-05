-- Shared primitives for agent99's tool modules: the coroutine helpers every
-- tool waits with, buffer loading with disk synchronisation, the LSP request
-- wrapper, position addressing, and the small path and project helpers.
--
-- Every function here runs inside the tool coroutine started by agent99.rpc
-- (see lsp.lua for the concurrency model). Nothing here is a tool; the tool
-- modules (index, edit, install, lsp) build on these.

local M = {}



local ATTACH_TIMEOUT_MS = 5000

local REQUEST_TIMEOUT_MS = 10000

local MAX_LOCATIONS = 100

local function err(fmt, ...)
    error(fmt:format(...), 0)
end

-- Run `start(resume)` and yield until `resume(...)` is called. Guarded so a
-- late second resume (e.g. an LSP reply after its timeout fired) is ignored,
-- and so a resume that happens synchronously inside `start` works too.
local function await(start)
    local co = assert(coroutine.running(), "agent99: await called outside a coroutine")
    local resumed, yielded = false, false
    local sync_result
    start(function(...)
        if resumed then return end
        resumed = true
        if not yielded then
            sync_result = { n = select("#", ...), ... }
            return
        end
        local ok, e = coroutine.resume(co, ...)
        if not ok then
            vim.notify("agent99 rpc: " .. tostring(e), vim.log.levels.ERROR)
        end
    end)
    if resumed then
        return unpack(sync_result, 1, sync_result.n)
    end
    yielded = true
    return coroutine.yield()
end

local function sleep(ms)
    await(function(resume)
        vim.defer_fn(resume, ms)
    end)
end

-- Load `file` into a (possibly hidden) buffer. bufload triggers filetype
-- detection, so vim.lsp.enable()-style auto-attach fires just as it would
-- for an interactively opened file.
local loaded_at = {}

-- Test files by the common conventions; the map leaves them out unless
-- asked, and find_symbol ranks them after production code.
local function is_test_path(path)
    return path:find("_test%.%w+$") or path:find("%.test%.%w+$")
        or path:find("%.spec%.%w+$") or path:find("^tests?/") or path:find("/tests?/")
        or path:find("^test_[^/]*%.py$") or path:find("/test_[^/]*%.py$")
        or path:find("/__tests__/") or path:find("/testdata/")
end

local function project_files(root)
    local files = vim.fn.systemlist({ "git", "-C", root,
        "ls-files", "--cached", "--others", "--exclude-standard" })
    if vim.v.shell_error ~= 0 then
        files = {}
        for _, f in ipairs(vim.fn.globpath(root, "**/*", true, true)) do
            if vim.fn.isdirectory(f) == 0 then
                files[#files + 1] = f:sub(#root + 2)
            end
        end
    end
    return files
end

-- How good a file is to hand a language server as its first sight of the
-- project. It matters more than it looks: a server like tsserver builds its
-- program from the files it has been given, so opening a stray bench script
-- gets it a one-file project and every whole-project query then comes back
-- empty. Source directories win, tests and scratch directories lose, and
-- shallow beats deep.
local SAMPLE_SOURCE_DIRS = { "src", "lib", "app", "pkg", "internal", "source" }

local SAMPLE_SIDE_DIRS = {
    bench = true, benchmarks = true, examples = true, example = true,
    docs = true, doc = true, scripts = true, tools = true, integration = true,
    fixtures = true, vendor = true, third_party = true, node_modules = true,
    playground = true, sandbox = true, demo = true,
}

local function sample_score(rel)
    local score = 0
    local first = rel:match("^([^/]+)/") or ""
    if SAMPLE_SIDE_DIRS[first] then
        score = score - 40
    end
    for _, dir in ipairs(SAMPLE_SOURCE_DIRS) do
        if rel:find("^" .. dir .. "/") or rel:find("/" .. dir .. "/") then
            score = score + 30
            break
        end
    end
    if is_test_path(rel) then
        score = score - 30
    end
    local depth = select(2, rel:gsub("/", ""))
    return score - depth
end

local function better_sample(a, b)
    if not a then return true end
    local sa, sb = sample_score(a), sample_score(b)
    if sa ~= sb then return sb > sa end
    return #b < #a
end

local function rel_path(path)
    local cwd = vim.fn.getcwd()
    if path:sub(1, #cwd + 1) == cwd .. "/" then
        return path:sub(#cwd + 2)
    end
    return path
end

local function disk_fingerprint(path)
    local st = vim.uv.fs_stat(path)
    if not st then return nil end
    return ("%d.%d/%d"):format(st.mtime.sec, st.mtime.nsec, st.size)
end

-- Remember that `bufnr` now agrees with what is on disk.
local function mark_synced(bufnr, path)
    path = path or vim.api.nvim_buf_get_name(bufnr)
    vim.b[bufnr].agent99_disk = disk_fingerprint(path)
end

-- Has the file changed behind the buffer's back since we last agreed with
-- it? Unknown fingerprints (buffer loaded before this ran) count as clean:
-- Neovim's own timestamp check still backs us up on the write.
local function disk_moved_on(bufnr, path)
    local seen = vim.b[bufnr].agent99_disk
    if not seen then return false end
    local now = disk_fingerprint(path)
    return now ~= nil and now ~= seen
end

-- Bring `bufnr` back in line with the file. An unmodified buffer is simply
-- reloaded. A buffer with edits of ours still in it cannot be: reloading
-- would throw those away and writing would throw the other change away, so
-- the caller is told and nothing is touched.
local function sync_buf(bufnr, path)
    if not disk_moved_on(bufnr, path) then return false end
    if vim.bo[bufnr].modified then
        err("%s changed on disk while this session had unsaved edits to it; "
            .. "nothing was written. Re-read the file and redo the edit, or "
            .. "undo_edit first", rel_path(path))
    end
    local ok, e = pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent! edit!")
    end)
    if not ok then
        err("could not reload %s after it changed on disk: %s", rel_path(path), tostring(e))
    end
    mark_synced(bufnr, path)
    loaded_at[bufnr] = vim.uv.now()
    return true
end

-- Write `bufnr` to disk. Refuses rather than clobbers when the file moved
-- on under us; `write!` itself never prompts, so this cannot hang.
local function write_buf(bufnr)
    if not vim.bo[bufnr].modified then return true end
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == "" then return true end
    if disk_moved_on(bufnr, path) then
        return false, ("%s changed on disk since this session read it; "
            .. "the edit was left unsaved in the editor"):format(rel_path(path))
    end
    local ok, e = pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent write!")
    end)
    if not ok then
        return false, ("could not write %s: %s"):format(rel_path(path), tostring(e))
    end
    mark_synced(bufnr, path)
    return true
end

-- Save every file buffer the tools have changed. Called by the bridge after
-- each edit tool in a headless workspace, and before shell commands that
-- read the tree. Returns a list of failures, empty when all is well.
function M.save_all()
    local failures = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified
            and vim.bo[b].buftype == "" and vim.api.nvim_buf_get_name(b) ~= "" then
            local ok, why = write_buf(b)
            if not ok then
                failures[#failures + 1] = why
            end
        end
    end
    return failures
end

-- Tell every language server that these files changed underneath it. A
-- server reads unopened files from disk and caches what it found, so until it
-- is told otherwise it keeps answering from the old content.
local function notify_changed_files(paths)
    if #paths == 0 then return end
    local changes = {}
    for _, path in ipairs(paths) do
        changes[#changes + 1] = { uri = vim.uri_from_fname(path), type = 2 }
    end
    for _, client in ipairs(vim.lsp.get_clients()) do
        pcall(function()
            client:notify("workspace/didChangeWatchedFiles", { changes = changes })
        end)
    end
end

-- Bring every buffer back in line with disk and tell the servers what moved.
--
-- Run before an edit is judged, because the judgement is about more than the
-- file being edited. A constant added to one file with a plain Edit, and a
-- use of it added to another through the symbol tools, is one change to the
-- project: report diagnostics on the second file while the server still has
-- the old first file and it says the constant is undefined. That reads as a
-- real error, and an agent that has been told to trust these diagnostics
-- then stops trusting them.
local function resync_open_buffers()
    local changed = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
            local path = vim.api.nvim_buf_get_name(bufnr)
            if path ~= "" and not vim.bo[bufnr].modified and disk_moved_on(bufnr, path) then
                if pcall(sync_buf, bufnr, path) then
                    changed[#changed + 1] = path
                end
            end
        end
    end
    notify_changed_files(changed)
    return changed
end

local function load_buf(file)
    if type(file) ~= "string" or file == "" then
        err("missing required argument: file")
    end
    local path = vim.fn.fnamemodify(file, ":p")
    if vim.fn.filereadable(path) == 0 then
        err("file not readable: %s", path)
    end
    local bufnr = vim.fn.bufadd(path)
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        vim.fn.bufload(bufnr)
        loaded_at[bufnr] = vim.uv.now()
        mark_synced(bufnr, path)
    else
        sync_buf(bufnr, path)
    end
    return bufnr, path
end

-- Buffers loaded within this window may have a server still indexing its
-- project (tsserver, gopls on a big module); whole-project queries that
-- come back near-empty are retried once after a pause.
local FRESH_BUF_MS = 15000

local FRESH_RETRY_MS = 1500

local function fresh_buf(bufnr)
    local t = loaded_at[bufnr]
    return t ~= nil and (vim.uv.now() - t) < FRESH_BUF_MS
end

-- Wait for an attached client that supports `method`. Attaching can take a
-- moment when the buffer was just loaded and the server is still starting.
-- Names of the enabled vim.lsp configs whose filetypes include ft.
local function enabled_lsp_configs_for(ft)
    local names = {}
    local ok, enabled = pcall(function() return vim.lsp._enabled_configs end)
    if not ok or type(enabled) ~= "table" then
        return names
    end
    for name in pairs(enabled) do
        local okc, cfg = pcall(function() return vim.lsp.config[name] end)
        if okc and type(cfg) == "table" then
            for _, cft in ipairs(cfg.filetypes or {}) do
                if cft == ft then
                    names[#names + 1] = name
                    break
                end
            end
        end
    end
    table.sort(names)
    return names
end

local function get_client(bufnr, method, timeout_ms)
    local deadline = vim.uv.now() + (timeout_ms or ATTACH_TIMEOUT_MS)
    while true do
        for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
            if c:supports_method(method, bufnr) then
                return c
            end
        end
        if vim.uv.now() >= deadline then
            err("no LSP client supporting %s is attached to %s (filetype: %s)",
                method, vim.api.nvim_buf_get_name(bufnr), vim.bo[bufnr].filetype)
        end
        sleep(100)
    end
end

-- LSP request that yields until the reply (or a timeout) arrives.
local function request(client, bufnr, method, params)
    local timer = vim.uv.new_timer()
    local rpc_err, result = await(function(resume)
        timer:start(REQUEST_TIMEOUT_MS, 0, vim.schedule_wrap(function()
            resume({ message = ("timed out after %d ms"):format(REQUEST_TIMEOUT_MS) }, nil)
        end))
        local ok = client:request(method, params, function(e, r)
            resume(e, r)
        end, bufnr)
        if not ok then
            resume({ message = "failed to send request" }, nil)
        end
    end)
    timer:stop()
    timer:close()
    if rpc_err then
        err("LSP error from %s for %s: %s", client.name, method,
            rpc_err.message or vim.inspect(rpc_err))
    end
    return result
end

local function make_position(bufnr, client, line, symbol, col)
    line = tonumber(line)
    if not line then
        err("missing required argument: line")
    end
    local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
    if text == nil then
        err("line %d is out of range in %s", line, vim.api.nvim_buf_get_name(bufnr))
    end
    local byte0
    if col then
        byte0 = tonumber(col) - 1
    elseif type(symbol) == "string" and symbol ~= "" then
        local s = text:find(symbol, 1, true)
        if not s then
            err("symbol %q not found on line %d, which reads: %s", symbol, line, text)
        end
        byte0 = s - 1
    else
        err("missing required argument: symbol (or col)")
    end
    local encoding = client.offset_encoding or "utf-16"
    local character = vim.str_utfindex(text, encoding, math.min(byte0, #text), false)
    return { line = line - 1, character = character }
end

local function position_params(bufnr, client, args)
    return {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        position = make_position(bufnr, client, args.line, args.symbol, args.col),
    }
end

-- Paths in results are relative to the working directory (the workspace
-- root in headless mode) when they lie under it; tools resolve relative
-- paths against the root, so the model can pass them straight back.
local function line_preview(path, lnum)
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        return vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    end
    local ok, lines = pcall(vim.fn.readfile, path, "", lnum)
    return ok and lines[lnum] or nil
end

local function decl_line(bufnr, lnum)
    local text = (vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or "")
        :gsub("^%s+", "")
    if #text > 120 then
        text = text:sub(1, 120) .. "…"
    end
    return text
end

-- Expand a glob against the project root. A glob with no "/" in it reads as
-- "this file, wherever it lives" ("schemas.ts"), but vim's globpath only
-- looks in the root itself, so retry that case one directory deep and then
-- anywhere. Returns the paths and, when there are none, why not.
local function expand_glob(root, glob)
    if type(root) ~= "string" or root == "" then
        err("glob needs the project root; pass explicit files instead")
    end
    local paths = vim.fn.globpath(root, glob, true, true)
    if #paths == 0 and not glob:find("/") then
        paths = vim.fn.globpath(root, "**/" .. glob, true, true)
    end
    if #paths == 0 then
        return paths, ("glob %q matched no files under %s; a glob is matched "
            .. "against the path from the root, so subdirectories need a "
            .. "\"**/\" prefix (\"**/*.ts\", \"**/schemas.ts\")"):format(glob, rel_path(root))
    end
    return paths
end

-- Filetypes with nothing to outline; a missing parser for these is not
-- worth a warning.
local DATA_FILETYPES = {
    text = true, gitignore = true, gitattributes = true, gitcommit = true,
    conf = true, dosini = true, json = true, jsonc = true, yaml = true,
    toml = true, markdown = true, gomod = true, gosum = true, license = true,
    csv = true, xml = true, html = true, css = true, svg = true,
    ["" ] = true,
}

local function has_parser(ft)
    local lang = vim.treesitter.language.get_lang(ft) or ft
    -- add() returns nil (no error) for a missing parser on recent Neovim;
    -- inspect() is the reliable "is it loaded" probe.
    pcall(vim.treesitter.language.add, lang)
    return (pcall(vim.treesitter.language.inspect, lang))
end

local function client_for(bufnr, method)
    for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if c:supports_method(method, bufnr) then
            return c
        end
    end
    return nil
end
-- In a live editor the user saves too, and their write is as authoritative
-- as ours; without this their next keystroke would look like a buffer that
-- disagrees with the disk.
vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost" }, {
    group = vim.api.nvim_create_augroup("agent99_disk_state", { clear = true }),
    callback = function(ev)
        local name = vim.api.nvim_buf_get_name(ev.buf)
        if name ~= "" then
            mark_synced(ev.buf, name)
        end
    end,
})

M.ATTACH_TIMEOUT_MS = ATTACH_TIMEOUT_MS
M.REQUEST_TIMEOUT_MS = REQUEST_TIMEOUT_MS
M.MAX_LOCATIONS = MAX_LOCATIONS
M.FRESH_RETRY_MS = FRESH_RETRY_MS
M.DATA_FILETYPES = DATA_FILETYPES
M.err = err
M.await = await
M.sleep = sleep
M.is_test_path = is_test_path
M.project_files = project_files
M.better_sample = better_sample
M.rel_path = rel_path
M.disk_fingerprint = disk_fingerprint
M.mark_synced = mark_synced
M.disk_moved_on = disk_moved_on
M.sync_buf = sync_buf
M.write_buf = write_buf
M.notify_changed_files = notify_changed_files
M.resync_open_buffers = resync_open_buffers
M.load_buf = load_buf
M.fresh_buf = fresh_buf
M.enabled_lsp_configs_for = enabled_lsp_configs_for
M.get_client = get_client
M.request = request
M.make_position = make_position
M.position_params = position_params
M.line_preview = line_preview
M.decl_line = decl_line
M.expand_glob = expand_glob
M.has_parser = has_parser
M.client_for = client_for

return M
