-- What a workspace can and cannot do, and how to fix that: the language
-- support probe open_workspace reports, install_language (tree-sitter parser
-- plus Mason server for one filetype), and check_project, the one
-- project-wide check whose baseline lets later calls report only what
-- changed.

local M = {}

local core = require("agent99.core")
local err, await, sleep, load_buf, rel_path = core.err, core.await, core.sleep, core.load_buf, core.rel_path
local project_files, better_sample, has_parser = core.project_files, core.better_sample, core.has_parser
local enabled_lsp_configs_for, DATA_FILETYPES = core.enabled_lsp_configs_for, core.DATA_FILETYPES


-- check_project: one project-wide check (type checker, vet, cargo check)
-- with a baseline. The first run in a root records its output; later runs
-- report only lines that are new since the baseline and lines that went
-- away, so "is the project still green after my refactor" is one call
-- with a short answer.
local check_baseline = {}

local CHECK_MAX_LINES = 60

-- Guessed commands are all type checks and vetting, never test runners: they
-- have to be fast enough to run after an edit, and the question they answer is
-- "did I break a reference", not "does the suite pass". The reply says so,
-- because a green check here is easy to mistake for a green project.
local function guess_check_command(root)
    local function has(rel) return vim.uv.fs_stat(root .. "/" .. rel) ~= nil end
    -- Whether the project holds files with this extension, taken from the
    -- file list the rest of the plugin uses (git's, when there is a git) so
    -- that asking costs no extra walk of the tree.
    local function has_ext(ext)
        for _, rel in ipairs(project_files(root)) do
            if rel:sub(-#ext) == ext then return true end
        end
        return false
    end
    -- One entry per language the project mixes, not just the first match:
    -- a repo with a Go bridge and a Lua plugin (this one) needs both, or
    -- check_project silently covers only whichever language happened to be
    -- checked first.
    local guesses = {}
    local function add(cmd, note)
        guesses[#guesses + 1] = { cmd = cmd, note = note }
    end
    -- `go build ./...` writes a binary named after a lone main package into
    -- the cwd, which fails when a directory of that name exists (a repo with
    -- its main package in ./bridge). vet compiles everything without that.
    if has("go.mod") then
        add("go vet ./...")
    end
    if has("Cargo.toml") then
        add("cargo check --message-format short")
    end
    if has("tsconfig.json") then
        if has("node_modules/.bin/tsc") then
            add("node_modules/.bin/tsc --noEmit -p .")
        elseif vim.fn.executable("tsc") == 1 then
            add("tsc --noEmit -p .")
        end
    end
    if has("pyproject.toml") or has("setup.py") or has("setup.cfg") then
        if vim.fn.executable("pyright") == 1 then
            add("pyright")
        elseif vim.fn.executable("mypy") == 1 then
            add("mypy .")
        end
    end
    if has("CMakeLists.txt") and has("build") then
        add("cmake --build build")
    end
    -- QML has no compiler to run, and qmllint is the check every Qt project
    -- ends up writing a script around. Two things about it are worth saying
    -- once here rather than in every project: it takes files rather than a
    -- directory, and it exits 0 on warnings, while the flag that changes
    -- that (-W) does not exist on older Qt. The exit code is therefore not
    -- the gate for this command; the baseline diff is, since a new warning
    -- is still a new line.
    if vim.fn.executable("qmllint") == 1 and has_ext(".qml") then
        add("find . -name '*.qml' -not -path './.git/*' -print0 | xargs -0 -r qmllint",
            "qmllint reports warnings but still exits 0, so read the new lines rather "
            .. "than the exit code. It also checks one import path: types it cannot "
            .. "resolve are reported as warnings that say nothing about your change, "
            .. "which the baseline absorbs on the first call. Pass command= with your "
            .. "own -I flags when that noise hides real findings.")
    end
    -- Lua has no project-wide type checker to shell out to (lua_ls, the LSP
    -- this plugin already drives, is not a CLI); luacheck is the real lint
    -- but is an optional install, so prefer it when present and fall back
    -- to luac's own syntax-only parse check, which ships with Lua itself
    -- and needs nothing installed.
    if has_ext(".lua") then
        if vim.fn.executable("luacheck") == 1 then
            add("luacheck .",
                "luacheck reads .luacheckrc if the project has one; without one it uses "
                .. "its own defaults, which may flag style the project does not care "
                .. "about. Pass command= with your own flags (e.g. --config path) when "
                .. "that noise hides real findings.")
        else
            local luac = vim.fn.executable("luac") == 1 and "luac"
                or vim.fn.executable("luac5.4") == 1 and "luac5.4"
                or vim.fn.executable("luac5.1") == 1 and "luac5.1"
                or nil
            if luac then
                add(("find . -name '*.lua' -not -path './.git/*' -print0 | xargs -0 -n1 %s -p")
                    :format(luac),
                    ("%s -p is a syntax check only: it parses each file and catches what "
                        .. "breaks parsing, not an unused variable, an undefined global, or a "
                        .. "logic error. lua_ls's live diagnostics, already surfaced on every "
                        .. "edit through this server, cover more; this exists so a Lua project "
                        .. "still gets some check_project coverage where luacheck is not "
                        .. "installed."):format(luac))
            end
        end
    end
    return guesses
end

-- A check command the caller has chosen for this project, replacing the guess
-- for the rest of the session. The guess cannot know that a project needs its
-- tests run, or needs checking under a second set of build tags; whoever is
-- working in the repository does, and should not have to repeat it on every
-- call. Keyed by root, and persisted under Neovim's state directory: a
-- workspace is replaced whenever a session moves to another repository,
-- and a command remembered last week should not have to be given again.
local check_override

-- A store of commands remembered per root (check_project's check, run_tests'
-- runner), persisted under the state directory so a later session finds
-- them. Returns the in-memory table, filled from disk at creation, plus a
-- save for one root.
--
-- The file is shared by every Neovim instance on the machine, and each
-- holds its own copy of it from creation, so writing that copy back whole
-- would drop whatever another instance remembered since. save re-reads
-- the file first and replaces only this root's entry: a read-modify-write
-- with no lock, so two saves in the same instant can still race, but the
-- window is one write rather than a whole session. Entries other instances
-- added are taken into memory on the way, so a later call sees them too.
-- Roots that are gone (scratch checkouts, test copies) are dropped on
-- read, so the file never grows without bound.
local function command_store(name)
    local function path()
        local dir = vim.fn.stdpath("state") .. "/agent99"
        vim.fn.mkdir(dir, "p")
        return dir .. "/" .. name .. ".json"
    end
    local function read()
        local data = {}
        local ok, lines = pcall(vim.fn.readfile, path())
        if not ok or #lines == 0 then return data end
        local okd, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
        if okd and type(decoded) == "table" then
            for root, cmds in pairs(decoded) do
                if type(cmds) == "table" and vim.fn.isdirectory(root) == 1 then
                    data[root] = cmds
                end
            end
        end
        return data
    end
    local override = read()
    local function save(root)
        local data = read()
        for other, cmds in pairs(data) do
            if other ~= root and override[other] == nil then
                override[other] = cmds
            end
        end
        data[root] = override[root]
        local okj, text = pcall(vim.json.encode, data)
        if okj then
            pcall(vim.fn.writefile, { text }, path())
        end
    end
    return override, save
end

local check_store_save
check_override, check_store_save = command_store("check_commands")
local function save_check_overrides(root)
    check_store_save(root)
end
local function check_project(args)
    local root = args.root
    if type(root) ~= "string" or root == "" then
        root = vim.fn.getcwd()
    end
    local okc, config = pcall(require, "agent99.config")
    local configured = okc and config.options and config.options.post_edit
        and config.options.post_edit.check or nil

    -- Explicit for this call, then whatever was remembered for this root,
    -- then the environment, the user's config, and finally the guess.
    local cmds
    if type(args.commands) == "table" and #args.commands > 0 then
        cmds = {}
        for _, c in ipairs(args.commands) do
            if type(c) ~= "string" or c == "" then
                err("commands must be a list of non-empty shell commands")
            end
            cmds[#cmds + 1] = c
        end
    elseif type(args.command) == "string" and args.command ~= "" then
        cmds = { args.command }
    end
    local explicit = cmds ~= nil
    if not cmds and check_override[root] then cmds = check_override[root] end
    local from_env = os.getenv("AGENT99_CHECK")
    if not cmds and from_env and from_env ~= "" then cmds = { from_env } end
    if not cmds and configured and configured ~= "" then cmds = { configured } end
    local guessed, guess_note = false, nil
    if not cmds then
        local guesses = guess_check_command(root)
        if #guesses > 0 then
            cmds = {}
            local notes = {}
            for _, g in ipairs(guesses) do
                cmds[#cmds + 1] = g.cmd
                if g.note then notes[#notes + 1] = g.note end
            end
            guessed = true
            guess_note = #notes > 0 and table.concat(notes, "\n\n") or nil
        end
    end
    if not cmds then
        err("no check command: pass command= or commands=, set AGENT99_CHECK, "
            .. "or post_edit.check in setup()")
    end
    if explicit and args.remember then
        check_override[root] = cmds
        save_check_overrides(root)
    end
    -- Only for the baseline key and the reply; the commands are run one at a
    -- time below, not handed to a shell as one line.
    local cmd = table.concat(cmds, " ; ")
    local timeout = (okc and config.options and config.options.post_edit
        and config.options.post_edit.check_timeout_ms) or 5 * 60 * 1000
    -- Shell linters read the disk: flush what the tools changed first. In a
    -- live editor the user's buffers are theirs to save, so the check runs
    -- against the disk copies and the reply says which buffers it did not
    -- see, or a tool edit still sitting in a buffer reads as "clean".
    local unsaved, unsaved_buffers
    if args.headless then
        local failures = core.save_all()
        if #failures > 0 then
            unsaved = failures
        end
    else
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified and vim.bo[b].buftype == "" then
                local name = vim.api.nvim_buf_get_name(b)
                if name ~= "" and name:sub(1, #root + 1) == root .. "/" then
                    unsaved_buffers = unsaved_buffers or {}
                    unsaved_buffers[#unsaved_buffers + 1] = rel_path(name)
                end
            end
        end
    end
    local started = vim.uv.now()
    -- Run each command in turn rather than joining them into one shell line.
    -- Joining with ";" would report the last command's exit code and hide a
    -- failure in an earlier one; joining with "&&" would stop at the first
    -- failure and never check the other build configuration, which is the
    -- main reason for passing more than one command in the first place.
    local lines, exit, failed, timed_out = {}, 0, nil, nil
    for _, one in ipairs(cmds) do
        local result = await(function(resume)
            local ok, e = pcall(vim.system, { "sh", "-c", one }, {
                cwd = root, text = true, timeout = timeout,
            }, vim.schedule_wrap(function(r) resume(r) end))
            if not ok then resume({ code = -1, stderr = tostring(e) }) end
        end)
        local text = ((result.stdout or "") .. (result.stderr or "")):gsub("%s+$", "")
        if #cmds > 1 and text ~= "" then
            lines[#lines + 1] = ("$ %s"):format(one)
        end
        if text ~= "" then
            vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
        end
        -- vim.system kills a command that outruns its timeout with SIGTERM
        -- and reports 124; that is a different answer from "the check found
        -- something", and its partial output must not become the baseline.
        if result.code == 124 and result.signal == 15 and not timed_out then
            timed_out = one
        end
        if result.code ~= 0 and exit == 0 then
            exit, failed = result.code, one
        end
    end
    local out = {
        command = #cmds == 1 and cmd or nil,
        commands = #cmds > 1 and cmds or nil,
        guessed = guessed or nil,
        exit = exit,
        failed_command = failed,
        seconds = math.floor((vim.uv.now() - started) / 100) / 10,
        unsaved = unsaved,
        unsaved_buffers = unsaved_buffers,
        unsaved_note = unsaved_buffers and ("%d buffer%s ha%s unsaved changes; the check ran against the disk copies")
            :format(#unsaved_buffers, #unsaved_buffers == 1 and "" or "s", #unsaved_buffers == 1 and "s" or "ve")
            or nil,
    }
    if explicit and args.remember then
        out.remembered = "later check_project calls in this root use this without arguments, "
            .. "in this workspace and in later ones"
    elseif not explicit and check_override[root] then
        out.remembered = "using the command remembered for this root"
    end
    if guessed then
        out.covers = "type and reference checking only: this does not run the tests, "
            .. "and it checks one build configuration, so code behind another build tag "
            .. "or feature flag is not analyzed. If that is the wrong gate for this "
            .. "project, pass a better one: commands=[...] runs several (one per build "
            .. "configuration), and remember=true makes it the default for this root "
            .. "for the rest of the session."
        out.about_this_command = guess_note
    end
    local key = root .. "\0" .. cmd
    local base = check_baseline[key]
    if timed_out then
        out.timed_out = timed_out
        out.output = vim.list_slice(lines, 1, CHECK_MAX_LINES)
        if #lines > CHECK_MAX_LINES then out.output_truncated = #lines - CHECK_MAX_LINES end
        out.summary = ("timed out after %g s: the output is partial, and no baseline was "
            .. "recorded or compared from it. Raise post_edit.check_timeout_ms in setup() "
            .. "or pass a faster command."):format(timeout / 1000)
    elseif base and not args.reset then
        local base_set, now_set = {}, {}
        for _, l in ipairs(base) do base_set[l] = (base_set[l] or 0) + 1 end
        for _, l in ipairs(lines) do now_set[l] = (now_set[l] or 0) + 1 end
        local new, resolved = {}, {}
        for _, l in ipairs(lines) do
            if (base_set[l] or 0) > 0 then base_set[l] = base_set[l] - 1 else new[#new + 1] = l end
        end
        for _, l in ipairs(base) do
            if (now_set[l] or 0) > 0 then now_set[l] = now_set[l] - 1 else resolved[#resolved + 1] = l end
        end
        out.baseline_lines = #base
        out.new = vim.list_slice(new, 1, CHECK_MAX_LINES)
        if #new > CHECK_MAX_LINES then out.new_truncated = #new - CHECK_MAX_LINES end
        out.resolved = #resolved
        if #new == 0 then
            out.summary = exit == 0 and "clean, nothing new since the baseline"
                or "nothing new since the baseline (the check still fails as it did before)"
        else
            out.summary = ("%d new lines since the baseline"):format(#new)
        end
    else
        check_baseline[key] = lines
        out.baseline = "recorded; later calls report only what changed"
        out.output = vim.list_slice(lines, 1, CHECK_MAX_LINES)
        if #lines > CHECK_MAX_LINES then out.output_truncated = #lines - CHECK_MAX_LINES end
        if #lines == 0 and exit == 0 then out.summary = "clean" end
    end
    return out
end

-- Internal: what the editor can do for the languages in a workspace, so a
-- client that opened a headless instance learns up front when a language
-- has no parser (skim/find_symbol/ts_query blind) or no language server
-- (definition/references/hover/diagnostics blind). Counts files per
-- filetype from the git index, checks the parser instantly, and for the
-- filetypes that have an enabled LSP config loads one sample file and
-- waits briefly for a client to attach (the binary may be missing).
local SUPPORT_MAX_FILETYPES = 6

local SUPPORT_ATTACH_MS = 2500

-- A warning when a JavaScript or TypeScript project's dependencies are not
-- where the language server will look, or are a symlink escaping the root:
-- the two ways its diagnostics turn authoritative and wrong.
local function node_modules_note(root, by_ft)
    local js = (by_ft.typescript or 0) + (by_ft.typescriptreact or 0)
        + (by_ft.javascript or 0) + (by_ft.javascriptreact or 0)
    if js == 0 then return nil end
    local nm = root .. "/node_modules"
    local lstat = vim.uv.fs_lstat(nm)
    if not lstat then
        -- A pnpm/yarn workspace keeps packages in the repo root, not the
        -- package dir, so only warn when there is a manifest here to install.
        if vim.uv.fs_stat(root .. "/package.json") then
            return "node_modules is absent under this root: the language server will report "
                .. "unresolved-import errors that are about the missing install, not the code. "
                .. "Install dependencies (npm/pnpm/yarn install) before trusting diagnostics."
        end
        return nil
    end
    if lstat.type == "link" then
        local target = vim.uv.fs_realpath(nm)
        local real_root = vim.uv.fs_realpath(root) or root
        if target and target:sub(1, #real_root + 1) ~= real_root .. "/" then
            return ("node_modules is a symlink to %s, outside this root: a package may resolve "
                .. "into a different checkout and produce a plausible but wrong type error. "
                .. "Verify a suspicious import diagnostic against the real dependency."):format(target)
        end
    end
    return nil
end

local function workspace_support(args)
    local root = args.root
    if type(root) ~= "string" or root == "" then
        err("missing project root")
    end
    local files = project_files(root)
    local by_ft, sample, ext_cache = {}, {}, {}
    for _, rel in ipairs(files) do
        local ext = rel:match("%.([%w_]+)$") or rel
        local ft = ext_cache[ext]
        if ft == nil then
            ft = vim.filetype.match({ filename = rel }) or false
            ext_cache[ext] = ft
        end
        if ft then
            by_ft[ft] = (by_ft[ft] or 0) + 1
            if better_sample(sample[ft], rel) then
                sample[ft] = rel
            end
        end
    end
    local fts = vim.tbl_keys(by_ft)
    table.sort(fts, function(a, b) return by_ft[a] > by_ft[b] end)
    local out, blind = {}, {}
    for i, ft in ipairs(fts) do
        if i > SUPPORT_MAX_FILETYPES then break end
        local parser = has_parser(ft)
        local configs = enabled_lsp_configs_for(ft)
        -- What could run this language under a debugger, so a client
        -- learns the option exists even when the debug tools are off.
        -- Probed before the server starts: for Java the probe also adds
        -- the java-debug bundle to the jdtls config, which only counts
        -- for a client that has not started yet.
        local debugger
        if not DATA_FILETYPES[ft] then
            local okd, dbg = pcall(function()
                return require("agent99.dap").debugger_for(ft, root)
            end)
            if okd then debugger = dbg end
        end
        local clients = {}
        if #configs > 0 then
            local okb, bufnr = pcall(load_buf, root .. "/" .. sample[ft])
            if okb then
                local deadline = vim.uv.now() + SUPPORT_ATTACH_MS
                while vim.uv.now() < deadline do
                    for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
                        clients[#clients + 1] = c.name
                    end
                    if #clients > 0 then break end
                    sleep(100)
                end
            end
        end
        local entry = {
            filetype = ft,
            files = by_ft[ft],
            treesitter_parser = parser,
            lsp = #clients > 0 and table.concat(clients, ",") or "none",
            debugger = debugger,
        }
        if #clients == 0 and #configs > 0 then
            entry.lsp = "none (configured: " .. table.concat(configs, ",") .. ", did not attach)"
        end
        if not parser and #clients == 0 and not DATA_FILETYPES[ft] then
            blind[#blind + 1] = ft
        end
        out[#out + 1] = entry
    end
    local notes = {}
    if #blind > 0 then
        notes[#notes + 1] = ("no parser and no language server for %s: symbol, navigation and "
                .. "diagnostic tools will not work on those files; grep and read_file will. "
                .. "install_language(language) can add both")
            :format(table.concat(blind, ", "))
    end
    -- A JS/TS project whose dependencies are not installed makes the language
    -- server report a wall of unresolved-import errors that say nothing about
    -- the code, and the failure looks authoritative. Worse, a node_modules
    -- symlink escaping the root can resolve a package into another checkout,
    -- producing one plausible-but-wrong type error. Say so up front.
    local ok_dep, dep_note = pcall(node_modules_note, root, by_ft)
    if ok_dep and dep_note then
        notes[#notes + 1] = dep_note
    end
    return { languages = out, note = #notes > 0 and table.concat(notes, " ") or nil }
end

-- install_language: add a treesitter parser (nvim-treesitter) and a language
-- server (Mason) for one filetype to the running instance, so the symbol and
-- navigation tools start working on files open_workspace flagged as blind.
-- Both installs are optional pieces of the user's setup; each step reports
-- what it did or why it could not.
local INSTALL_PARSER_MS = 5 * 60 * 1000

local INSTALL_SERVER_MS = 8 * 60 * 1000

local INSTALL_ATTACH_MS = 8000

-- Preferred language server per filetype where Mason offers several; the
-- lspconfig name, mapped to a Mason package through mason-lspconfig.
local PREFERRED_SERVER = {
    c = "clangd", cpp = "clangd", objc = "clangd", objcpp = "clangd",
    go = "gopls", gomod = "gopls",
    python = "pyright",
    javascript = "ts_ls", javascriptreact = "ts_ls",
    typescript = "ts_ls", typescriptreact = "ts_ls",
    lua = "lua_ls",
    rust = "rust_analyzer",
    java = "jdtls",
    kotlin = "kotlin_language_server",
    ruby = "ruby_lsp",
    php = "intelephense",
    cs = "omnisharp",
    swift = "sourcekit",
    zig = "zls",
    sh = "bashls",
    html = "html", css = "cssls", json = "jsonls", yaml = "yamlls",
    dockerfile = "dockerls",
    terraform = "terraformls",
    elixir = "elixirls",
    haskell = "hls",
    scala = "metals",
    dart = "dartls",
    ocaml = "ocamllsp",
    nix = "nil_ls",
    vim = "vimls",
}

local function install_parser(ft, lang)
    if has_parser(ft) then
        return { language = lang, status = "already installed" }
    end
    local okts, ts = pcall(require, "nvim-treesitter")
    if not okts or type(ts.install) ~= "function" then
        return { language = lang, status = "skipped",
            note = "nvim-treesitter is not on the runtimepath; install the parser by hand" }
    end
    local available = {}
    pcall(function()
        for _, l in ipairs(ts.get_available()) do available[l] = true end
    end)
    if next(available) and not available[lang] then
        return { language = lang, status = "unsupported",
            note = "nvim-treesitter has no parser named " .. lang }
    end
    local task
    local okstart, start_err = pcall(function() task = ts.install({ lang }) end)
    if not okstart or type(task) ~= "table" or type(task.await) ~= "function" then
        return { language = lang, status = "failed",
            note = "could not start the install: " .. tostring(start_err or task) }
    end
    local timer = vim.uv.new_timer()
    local aerr, done = await(function(resume)
        timer:start(INSTALL_PARSER_MS, 0, vim.schedule_wrap(function()
            resume("timed out")
        end))
        task:await(function(e, r) resume(e, r) end)
    end)
    timer:stop()
    timer:close()
    if aerr then
        return { language = lang, status = "failed", note = tostring(aerr) }
    end
    -- Neovim caches "no such parser"; a fresh add() picks the new .so up.
    pcall(vim.treesitter.language.add, lang)
    if has_parser(ft) then
        return { language = lang, status = "installed" }
    end
    return { language = lang, status = "failed",
        note = done == false and "nvim-treesitter reported the install as failed"
            or "install finished but the parser still does not load" }
end

-- vim.lsp.get_log_path is deprecated from 0.11 in favour of
-- vim.lsp.log.get_filename; take whichever this Neovim has.
local function lsp_log_path()
    if vim.lsp.log and vim.lsp.log.get_filename then
        return vim.lsp.log.get_filename()
    end
    ---@diagnostic disable-next-line: deprecated
    return vim.lsp.get_log_path()
end

local function attached_client(root, ft)
    local files = vim.fn.systemlist({ "git", "-C", root,
        "ls-files", "--cached", "--others", "--exclude-standard" })
    if vim.v.shell_error ~= 0 then
        files = vim.tbl_map(function(f) return f:sub(#root + 2) end,
            vim.fn.globpath(root, "**/*", true, true))
    end
    local sample
    for _, rel in ipairs(files) do
        if vim.filetype.match({ filename = rel }) == ft then
            sample = rel
            break
        end
    end
    if not sample then
        return nil, "no " .. ft .. " file in the workspace to try"
    end
    -- Server configs explain a refusal to start through vim.notify
    -- ("cargo not found"); collect those so the reply says why.
    local notices, orig_notify, orig_once = {}, vim.notify, vim.notify_once
    local function collect(msg, level)
        if type(msg) == "string" and (level or 0) >= vim.log.levels.WARN then
            notices[#notices + 1] = msg:gsub("%s+", " ")
        end
    end
    vim.notify = function(msg, level, opts)
        collect(msg, level)
        return orig_notify(msg, level, opts)
    end
    vim.notify_once = function(msg, level, opts)
        collect(msg, level)
        return orig_once(msg, level, opts)
    end
    -- Everything between the swap and the restore runs under pcall, so an
    -- error (or a bad sample file) cannot leave vim.notify hijacked for the
    -- rest of the session; the error is re-raised once the originals are
    -- back. The wait yields the coroutine, and LuaJIT allows that inside
    -- pcall.
    local okb, bufnr = pcall(load_buf, root .. "/" .. sample)
    local client
    local okw, werr = pcall(function()
        if not okb then return end
        -- The sample may have been loaded before the server existed (the
        -- open_workspace probe does that); re-setting the filetype fires
        -- FileType again so vim.lsp.enable's autocmd gets a second chance.
        if #vim.lsp.get_clients({ bufnr = bufnr }) == 0 then
            pcall(function() vim.bo[bufnr].filetype = ft end)
        end
        local deadline = vim.uv.now() + INSTALL_ATTACH_MS
        while vim.uv.now() < deadline do
            local clients = vim.lsp.get_clients({ bufnr = bufnr })
            if #clients > 0 then
                client = clients[1].name
                break
            end
            sleep(200)
        end
    end)
    vim.notify, vim.notify_once = orig_notify, orig_once
    if not okw then
        error(werr, 0)
    end
    if client then
        return client
    end
    if not okb then
        return nil, "could not load " .. sample
    end
    local why = "no client attached to " .. sample .. " within "
        .. (INSTALL_ATTACH_MS / 1000) .. "s"
    if #notices > 0 then
        why = why .. ": " .. table.concat(notices, "; ")
    else
        why = why .. "; the server's config may need a toolchain on PATH "
            .. "(rust_analyzer wants cargo, jdtls a JDK); see " .. lsp_log_path()
    end
    return nil, why
end

-- A language server Mason does not package can still be on the machine:
-- Qt ships qmlls with the distro, and some toolchains carry their own. Look
-- through the lspconfig configs on the runtimepath for one that covers the
-- filetype and whose command is executable here, including the versioned
-- name a distro may install it under (qmlls6 for qmlls, clangd-19 for
-- clangd), so a language is called unsupported only when nothing can run it.
local function system_server(ft, wanted)
    local seen, versioned = {}, nil
    for _, path in ipairs(vim.api.nvim_get_runtime_file("lsp/*.lua", true)) do
        local name = vim.fn.fnamemodify(path, ":t:r")
        if not seen[name] and (not wanted or wanted == "" or name == wanted) then
            seen[name] = true
            local okc, cfg = pcall(function() return vim.lsp.config[name] end)
            if okc and type(cfg) == "table" and vim.tbl_contains(cfg.filetypes or {}, ft)
                and type(cfg.cmd) == "table" and type(cfg.cmd[1]) == "string" then
                local cmd = cfg.cmd[1]
                if vim.fn.executable(cmd) == 1 then
                    return name, cmd
                end
                if not versioned then
                    local variants = vim.fn.getcompletion(cmd, "shellcmd")
                    table.sort(variants, function(a, b) return #a < #b end)
                    for _, v in ipairs(variants) do
                        if v:sub(1, #cmd) == cmd and vim.fn.executable(v) == 1 then
                            versioned = { name = name, cmd = v }
                            break
                        end
                    end
                end
            end
        end
    end
    if versioned then
        return versioned.name, versioned.cmd
    end
end

-- Enable a server that is already on the machine, pointing its config at
-- the command that actually exists, and report whether it attached.
local function enable_system_server(ft, name, cmd, root, why)
    local out = { lspconfig = name, cmd = cmd, status = "on the system" }
    local okcfg = pcall(function()
        local current = (vim.lsp.config[name] or {}).cmd
        if type(current) ~= "table" then
            vim.lsp.config(name, { cmd = { cmd } })
        elseif current[1] ~= cmd then
            -- Replace only the executable: a versioned binary (clangd-18)
            -- stands in for the plain name, and the config's own arguments
            -- ("--stdio", "--background-index") still apply to it.
            local replaced = vim.list_extend({ cmd }, vim.list_slice(current, 2))
            vim.lsp.config(name, { cmd = replaced })
        end
    end)
    if not okcfg then
        out.note = "could not set the command of " .. name .. " to " .. cmd
        return out
    end
    pcall(vim.lsp.enable, name)
    out.note = ("%s; %s is installed on this machine and was enabled")
        :format(why or ("Mason has no server for " .. ft), cmd)
    if type(root) == "string" and root ~= "" then
        local client, cwhy = attached_client(root, ft)
        if client then
            out.attached = client
        else
            out.attached = false
            out.note = out.note .. ", but " .. cwhy
        end
    end
    return out
end
local function install_server(ft, wanted, root)
    local okreg, registry = pcall(require, "mason-registry")
    local okml, mlsp = pcall(require, "mason-lspconfig")
    if not okreg or not okml then
        return { status = "skipped",
            note = "mason.nvim and mason-lspconfig.nvim are needed to install servers; "
                .. "install one by hand and enable it with vim.lsp.enable()" }
    end
    local maps = mlsp.get_mappings()
    -- Resolve the wanted server: an explicit name may be a Mason package or
    -- an lspconfig name; otherwise the preferred server for the filetype,
    -- else whatever Mason offers for it.
    local candidates = {}
    pcall(function()
        candidates = mlsp.get_available_servers({ filetype = ft })
    end)
    table.sort(candidates)
    local lspname, package
    if wanted and wanted ~= "" then
        if maps.package_to_lspconfig[wanted] then
            package, lspname = wanted, maps.package_to_lspconfig[wanted]
        elseif maps.lspconfig_to_package[wanted] then
            lspname, package = wanted, maps.lspconfig_to_package[wanted]
        else
            local sysname, syscmd = system_server(ft, wanted)
            if sysname then
                return enable_system_server(ft, sysname, syscmd, root)
            end
            return {
                status = "unknown",
                note = ("Mason has no package or server named %s; servers for %s: %s")
                    :format(wanted, ft, #candidates > 0 and table.concat(candidates, ", ") or "none")
            }
        end
    else
        lspname = PREFERRED_SERVER[ft]
        if not lspname or not maps.lspconfig_to_package[lspname] then
            -- An already enabled config for this filetype wins over a fresh pick.
            for _, name in ipairs(enabled_lsp_configs_for(ft)) do
                if maps.lspconfig_to_package[name] then
                    lspname = name
                    break
                end
            end
        end
        if not lspname or not maps.lspconfig_to_package[lspname] then
            lspname = candidates[1]
        end
        if not lspname then
            local sysname, syscmd = system_server(ft)
            if sysname then
                return enable_system_server(ft, sysname, syscmd, root)
            end
            return {
                status = "unsupported",
                note = "Mason offers no language server for filetype " .. ft
            }
        end
        package = maps.lspconfig_to_package[lspname]
    end
    local out = { package = package, lspconfig = lspname }
    if #candidates > 1 then
        out.alternatives = vim.tbl_filter(function(c) return c ~= lspname end, candidates)
    end
    -- Mason lists a package it cannot always supply: qmlls has no build for
    -- every platform, and an install that fails leaves the language with no
    -- server at all. When the machine already carries one, enabling it is a
    -- better answer than reporting the failure and stopping there.
    local function or_system(failed)
        local sysname, syscmd = system_server(ft, lspname)
        if not sysname then
            sysname, syscmd = system_server(ft)
        end
        if not sysname then
            return failed
        end
        local res = enable_system_server(ft, sysname, syscmd, root,
            ("Mason could not install a server for %s (%s)"):format(ft, failed.note))
        res.mason_package = failed.package
        return res
    end
    local pkg
    local okp = pcall(function() pkg = registry.get_package(package) end)
    if not okp or not pkg then
        out.status = "unknown"
        out.note = "Mason registry has no package " .. package
        return or_system(out)
    end
    if pkg:is_installed() then
        out.status = "already installed"
    else
        await(function(resume)
            pcall(registry.refresh, function() resume() end)
        end)
        local timer = vim.uv.new_timer()
        local timed_out = await(function(resume)
            timer:start(INSTALL_SERVER_MS, 0, vim.schedule_wrap(function()
                resume(true)
            end))
            local okh, herr = pcall(function()
                pkg:install():once("closed", vim.schedule_wrap(function() resume(false) end))
            end)
            if not okh then
                out.start_error = tostring(herr)
                resume(false)
            end
        end)
        timer:stop()
        timer:close()
        if timed_out then
            out.status = "failed"
            out.note = "install did not finish within " .. (INSTALL_SERVER_MS / 60000) .. " minutes"
            return or_system(out)
        end
        if not pkg:is_installed() then
            out.status = "failed"
            out.note = (out.start_error or "Mason reported the install as failed")
                .. "; see :MasonLog (" .. vim.fn.stdpath("log") .. "/mason.log)"
            out.start_error = nil
            return or_system(out)
        end
        out.status = "installed"
    end
    -- mason-lspconfig enables freshly installed servers itself when its
    -- automatic_enable is on; doing it here too is idempotent and covers
    -- the "already installed but never enabled" case.
    pcall(vim.lsp.enable, lspname)
    local cmd = vim.tbl_get(vim.lsp.config, lspname, "cmd")
    if type(cmd) == "table" and type(cmd[1]) == "string" and vim.fn.executable(cmd[1]) == 0 then
        out.attached = false
        out.note = cmd[1] .. " is not executable from this Neovim (Mason's bin dir "
            .. "is added to PATH by mason.setup(); is that in the config?)"
        return out
    end
    if type(root) == "string" and root ~= "" then
        local client, why = attached_client(root, ft)
        if client then
            out.attached = client
        else
            out.attached = false
            out.note = why
        end
    end
    return out
end

local function install_language(args)
    local ft = args.language
    if type(ft) ~= "string" or ft == "" then
        err("missing required argument: language")
    end
    ft = ft:lower()
    -- Accept a file extension or a treesitter name too ("ts", "cpp", "c++").
    ft = vim.filetype.match({ filename = "x." .. ft }) or ft
    local lang = vim.treesitter.language.get_lang(ft) or ft
    local result = { language = ft }
    if args.parser ~= false then
        result.parser = install_parser(ft, lang)
    else
        result.parser = { status = "skipped" }
    end
    if args.server ~= "none" then
        result.server = install_server(ft, args.server, args.root)
    else
        result.server = { status = "skipped" }
    end
    result.note = "installed pieces live in Neovim's data directory and survive restarts; "
        .. "add them to the editor config's ensure_installed lists to keep them on a fresh machine"
    return result
end
M.check_project = check_project
M.command_store = command_store
M.workspace_support = workspace_support
M.install_language = install_language

return M
