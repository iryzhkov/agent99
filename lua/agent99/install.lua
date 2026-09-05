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
local resync_open_buffers, write_buf, disk_moved_on = core.resync_open_buffers, core.write_buf, core.disk_moved_on
local post_edit_options = require("agent99.edit").post_edit_options


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
    -- `go build ./...` writes a binary named after a lone main package into
    -- the cwd, which fails when a directory of that name exists (a repo with
    -- its main package in ./bridge). vet compiles everything without that.
    if has("go.mod") then return "go vet ./..." end
    if has("Cargo.toml") then return "cargo check --message-format short" end
    if has("tsconfig.json") then
        if has("node_modules/.bin/tsc") then return "node_modules/.bin/tsc --noEmit -p ." end
        if vim.fn.executable("tsc") == 1 then return "tsc --noEmit -p ." end
    end
    if has("pyproject.toml") or has("setup.py") or has("setup.cfg") then
        if vim.fn.executable("pyright") == 1 then return "pyright" end
        if vim.fn.executable("mypy") == 1 then return "mypy ." end
    end
    if has("CMakeLists.txt") and has("build") then return "cmake --build build" end
    return nil
end

-- A check command the caller has chosen for this project, replacing the guess
-- for the rest of the session. The guess cannot know that a project needs its
-- tests run, or needs checking under a second set of build tags; whoever is
-- working in the repository does, and should not have to repeat it on every
-- call. Keyed by root, and persisted under Neovim's state directory: a
-- workspace is replaced whenever a session moves to another repository,
-- and a command remembered last week should not have to be given again.
local check_override = {}

local function check_store_path()
    local dir = vim.fn.stdpath("state") .. "/agent99"
    vim.fn.mkdir(dir, "p")
    return dir .. "/check_commands.json"
end

local function load_check_overrides()
    local ok, lines = pcall(vim.fn.readfile, check_store_path())
    if not ok or #lines == 0 then return end
    local okd, data = pcall(vim.json.decode, table.concat(lines, "\n"))
    if okd and type(data) == "table" then
        for root, cmds in pairs(data) do
            -- Roots that are gone (scratch checkouts, test copies) are
            -- dropped here, so the file never grows without bound.
            if type(cmds) == "table" and vim.fn.isdirectory(root) == 1 then
                check_override[root] = cmds
            end
        end
    end
end

local function save_check_overrides()
    local okj, text = pcall(vim.json.encode, check_override)
    if okj then
        pcall(vim.fn.writefile, { text }, check_store_path())
    end
end

load_check_overrides()
local function check_project(args)
    local root = args.root
    if type(root) ~= "string" or root == "" then
        root = vim.fn.getcwd()
    end
    local opts = post_edit_options()
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
    local guessed = false
    if not cmds then
        local guess = guess_check_command(root)
        if guess then
            cmds = { guess }
            guessed = true
        end
    end
    if not cmds then
        err("no check command: pass command= or commands=, set AGENT99_CHECK, "
            .. "or post_edit.check in setup()")
    end
    if explicit and args.remember then
        check_override[root] = cmds
        save_check_overrides()
    end
    -- Only for the baseline key and the reply; the commands are run one at a
    -- time below, not handed to a shell as one line.
    local cmd = table.concat(cmds, " ; ")
    local timeout = (okc and config.options and config.options.post_edit
        and config.options.post_edit.check_timeout_ms) or 5 * 60 * 1000
    -- Shell linters read the disk: flush what the tools changed first.
    local unsaved
    if args.headless then
        local failures = core.save_all()
        if #failures > 0 then
            unsaved = failures
        end
    end
    local started = vim.uv.now()
    -- Run each command in turn rather than joining them into one shell line.
    -- Joining with ";" would report the last command's exit code and hide a
    -- failure in an earlier one; joining with "&&" would stop at the first
    -- failure and never check the other build configuration, which is the
    -- main reason for passing more than one command in the first place.
    local lines, exit, failed = {}, 0, nil
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
    end
    local key = root .. "\0" .. cmd
    local base = check_baseline[key]
    if base and not args.reset then
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
    local okb, bufnr = pcall(load_buf, root .. "/" .. sample)
    local client
    if okb then
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
    end
    vim.notify, vim.notify_once = orig_notify, orig_once
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
            .. "(rust_analyzer wants cargo, jdtls a JDK); see " .. vim.lsp.get_log_path()
    end
    return nil, why
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
            return { status = "unknown",
                note = ("Mason has no package or server named %s; servers for %s: %s")
                    :format(wanted, ft, #candidates > 0 and table.concat(candidates, ", ") or "none") }
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
            return { status = "unsupported",
                note = "Mason offers no language server for filetype " .. ft }
        end
        package = maps.lspconfig_to_package[lspname]
    end
    local out = { package = package, lspconfig = lspname }
    if #candidates > 1 then
        out.alternatives = vim.tbl_filter(function(c) return c ~= lspname end, candidates)
    end
    local pkg
    local okp = pcall(function() pkg = registry.get_package(package) end)
    if not okp or not pkg then
        out.status = "unknown"
        out.note = "Mason registry has no package " .. package
        return out
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
            return out
        end
        if not pkg:is_installed() then
            out.status = "failed"
            out.note = (out.start_error or "Mason reported the install as failed")
                .. "; see :MasonLog (" .. vim.fn.stdpath("log") .. "/mason.log)"
            out.start_error = nil
            return out
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
M.workspace_support = workspace_support
M.install_language = install_language

return M
