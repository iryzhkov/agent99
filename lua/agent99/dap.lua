-- Debugger tools for agent99: a Debug Adapter Protocol session driven
-- through nvim-dap inside the Neovim instance the bridge already owns.
--
-- Everything here runs in the tool coroutine started by agent99.rpc, so a
-- wait for the next stop is an `await` on a callback the nvim-dap listeners
-- fire, raced against a timer - the same shape as an LSP request in
-- agent99.lsp. The session, its output and the breakpoints the agent placed
-- live in one module-level table, mirroring check_baseline: one instance,
-- one session, dying with the instance.
--
-- nvim-dap is an optional dependency. Without it every tool here explains
-- how to add it and returns; nothing else in agent99 changes.

local M = {}

local REQUEST_TIMEOUT_MS = 10000
local DEFAULT_WAIT_MS = 30000
-- The bridge allows these tools five minutes; the Lua side always returns
-- first, so a bridge timeout never leaves a coroutine waiting on a session
-- whose reply nobody reads.
local MAX_WAIT_MS = 240000
local ADAPTER_START_MS = 15000
local STOP_GRACE_MS = 5000
local IDLE_CHECK_MS = 60000
local OUTPUT_CAP_LINES = 400
local OUTPUT_CAP_BYTES = 64 * 1024
local OUTPUT_NEW_MAX = 30
local OUTPUT_TAIL_MAX = 200
local LOCALS_MAX = 12
local VARIABLES_MAX = 40
local STACK_MAX = 6
local STACK_DEPTH_DEFAULT = 12
local VALUE_CLIP = 120
local SOURCE_CONTEXT = 2

local uv = vim.uv

local function err(fmt, ...)
    error(fmt:format(...), 0)
end

-- Helpers shared with agent99.lsp (await, load_buf, symbol index, ...).
local function I()
    return require("agent99.lsp")._internal
end

local function has_dap()
    local ok, dap = pcall(require, "dap")
    if ok then return dap end
    return nil
end

local NO_DAP = "nvim-dap is not on the runtimepath of this Neovim; add "
    .. "`mfussenegger/nvim-dap` to your plugin spec (agent99 lists it as an "
    .. "optional dependency) and restart"

local function need_dap()
    local dap = has_dap()
    if not dap then err("%s", NO_DAP) end
    return dap
end

local function options()
    local ok, config = pcall(require, "agent99.config")
    local opts = ok and config.options and config.options.debug or {}
    local idle = tonumber(os.getenv("AGENT99_DEBUG_IDLE_MS")) or opts.idle_ms or 600000
    return { idle_ms = idle }
end

local function now()
    return uv.now()
end

------------------------------------------------------------------------
-- Session state
------------------------------------------------------------------------

local function new_state()
    return {
        session = nil,
        origin = nil,      -- "agent" | "user"
        request = nil,     -- "launch" | "attach"
        adapter = nil,     -- adapter name for replies
        config = nil,      -- the nvim-dap configuration that was run
        launch_args = nil, -- the tool arguments, for relaunch
        started = nil,
        last_used = nil,
        output = {},        -- ring buffer of lines
        output_bytes = 0,
        output_cursor = 0,  -- lines already shown in a reply
        output_dropped = 0, -- lines that fell off the front of the ring
        breakpoints = {},   -- ledger: { bufnr, line, file }
        fingerprints = {},  -- file -> disk fingerprint at launch
        waiter = nil,       -- { tool, since, resume }
        stop = nil,         -- last stopped-event body
        exit = nil,         -- { code, reason }
        variables_mode = "summary",
        track = {},
        launch_error = nil,
        adapter_proc = nil, -- uv handle of an adapter this module spawned
        adapter_stderr = {},
    }
end

local state = new_state()
-- Output of the previous session survives until the next launch.
local last_output = nil
local listeners_installed = false
local idle_timer = nil

local function touch()
    state.last_used = now()
end

local function push_output(line, tag)
    if tag then line = tag .. line end
    local out = state.output
    out[#out + 1] = line
    state.output_bytes = state.output_bytes + #line
    while #out > OUTPUT_CAP_LINES or (state.output_bytes > OUTPUT_CAP_BYTES and #out > 1) do
        state.output_bytes = state.output_bytes - #out[1]
        table.remove(out, 1)
        state.output_dropped = state.output_dropped + 1
        if state.output_cursor > 0 then
            state.output_cursor = state.output_cursor - 1
        end
    end
end

-- Adapters send output in chunks that need not end at a line boundary
-- (debugpy splits one print into several); complete lines go into the
-- ring, the rest waits for its newline or for flush_output.
local partial = {}
local function push_output_chunk(text, tag)
    if type(text) ~= "string" or text == "" then return end
    tag = tag or ""
    text = (partial[tag] or "") .. text:gsub("\r", "")
    local last_nl = text:match(".*()\n")
    if not last_nl then
        partial[tag] = text
        return
    end
    for line in text:sub(1, last_nl - 1):gmatch("[^\n]*") do
        if line ~= "" then push_output(line, tag) end
    end
    local rest = text:sub(last_nl + 1)
    partial[tag] = rest ~= "" and rest or nil
end

local function flush_output()
    for tag, text in pairs(partial) do
        if text ~= "" then push_output(text, tag) end
        partial[tag] = nil
    end
end
-- Lines appended since the last reply, capped, with a note for the rest.
local function output_new()
    flush_output()
    local out = state.output
    local from = state.output_cursor + 1
    local total = #out - state.output_cursor
    state.output_cursor = #out
    if total <= 0 then return nil end
    local lines = {}
    local start = from
    if total > OUTPUT_NEW_MAX then
        start = #out - OUTPUT_NEW_MAX + 1
    end
    for i = start, #out do
        lines[#lines + 1] = out[i]
    end
    if total > OUTPUT_NEW_MAX then
        table.insert(lines, 1, ("+%d earlier lines, debug_output(tail=%d) has them"):format(
            total - OUTPUT_NEW_MAX, math.min(total, OUTPUT_TAIL_MAX)))
    end
    return lines
end

local function output_tail(n)
    flush_output()
    local out = state.output
    n = math.min(n or 40, #out)
    local lines = {}
    for i = #out - n + 1, #out do
        lines[#lines + 1] = out[i]
    end
    return lines
end

------------------------------------------------------------------------
-- Waiting for the session
------------------------------------------------------------------------

local function clamp_wait(ms, default)
    ms = tonumber(ms)
    if ms == nil then ms = default or DEFAULT_WAIT_MS end
    if ms < 0 then ms = 0 end
    return math.min(ms, MAX_WAIT_MS)
end

-- Resume whoever is waiting for the next session event.
local function wake(kind, body)
    local w = state.waiter
    if not w then return end
    state.waiter = nil
    w.resume(kind, body)
end

-- Block the tool until the next stop/exit/failure or the timeout. Returns
-- "stopped" | "exited" | "failed" | "timeout". Only one tool may wait at a
-- time; the second one is told who is already waiting.
local function wait_event(tool, ms)
    if state.waiter then
        err("%s is already waiting since %d s; call debug_wait(wait_ms=0) for the current state",
            state.waiter.tool, math.floor((now() - state.waiter.since) / 1000))
    end
    -- An event that arrived while the request that caused it was still
    -- being answered (Delve sends `stopped` before the `pause` response)
    -- is already recorded; do not wait for a second one.
    if state.stop then return "stopped", state.stop end
    if state.exit then return "exited" end
    if state.launch_error then return "failed" end
    if ms <= 0 then return "timeout" end
    local timer = uv.new_timer()
    local kind, body = I().await(function(resume)
        state.waiter = { tool = tool, since = now(), resume = resume }
        timer:start(ms, 0, vim.schedule_wrap(function()
            if state.waiter and state.waiter.resume == resume then
                state.waiter = nil
            end
            resume("timeout")
        end))
    end)
    timer:stop()
    timer:close()
    return kind, body
end

-- One DAP request with a timeout; errors name the request and adapter.
local function request(session, command, arguments)
    if not session or session.closed then
        err("no debug session: start one with debug_launch or debug_attach")
    end
    local timer = uv.new_timer()
    local rpc_err, result = I().await(function(resume)
        timer:start(REQUEST_TIMEOUT_MS, 0, vim.schedule_wrap(function()
            resume({ message = ("timed out after %d ms"):format(REQUEST_TIMEOUT_MS) }, nil)
        end))
        local ok, e = pcall(session.request, session, command, arguments, function(e2, r)
            resume(e2, r)
        end)
        if not ok then
            resume({ message = tostring(e) }, nil)
        end
    end)
    timer:stop()
    timer:close()
    if rpc_err then
        local msg = rpc_err.message or vim.inspect(rpc_err)
        local body = rpc_err.body and rpc_err.body.error
        if body and body.format and body.format ~= msg then
            msg = msg .. ": " .. body.format
        end
        err("DAP request %s failed (%s): %s", command, state.adapter or "adapter", msg)
    end
    return result
end

-- Like request, but returns (err, result) instead of raising.
local function try_request(session, command, arguments)
    local ok, r = pcall(request, session, command, arguments)
    if ok then return nil, r end
    return r, nil
end

------------------------------------------------------------------------
-- Listeners: one set, installed once, keyed "agent99"
------------------------------------------------------------------------

-- Ours: the session we started or adopted, or a child of it (js-debug
-- runs the program in a child session opened by a startDebugging request).
local function our_session(session)
    if state.session == nil or session == nil then return false end
    local s = session
    for _ = 1, 8 do
        if s == state.session then return true end
        s = s.parent
        if s == nil then return false end
    end
    return false
end

-- The session requests go to: the child that last stopped, else the root.
local function active_session()
    local a = state.active
    if a and not a.closed and our_session(a) then return a end
    return state.session
end

-- Root and every live child, for breakpoint updates.
local function all_sessions()
    local out = {}
    local function add(s)
        if not s or s.closed then return end
        out[#out + 1] = s
        for _, child in pairs(s.children or {}) do add(child) end
    end
    add(state.session)
    return out
end
local function session_ended(reason)
    if state.exit == nil then
        state.exit = { reason = reason }
    end
end

local function install_listeners(dap)
    if listeners_installed then return end
    listeners_installed = true
    local L = dap.listeners
    local key = "agent99"

    L.before.event_initialized[key] = function(session)
        -- The session object exists now; a launch we started claims it.
        if state.session == nil and state.claiming then
            state.session = session
            state.claiming = false
            wake("initialized")
        end
    end
    L.after.event_stopped[key] = function(session, body)
        if not our_session(session) then return end
        state.active = session
        state.stop = body or {}
        state.stop.at = now()
        wake("stopped", body)
    end
    L.after.event_exited[key] = function(session, body)
        if not our_session(session) then return end
        state.exit = { code = body and body.exitCode, reason = "exited" }
        wake("exited", body)
    end
    L.after.event_terminated[key] = function(session)
        if not our_session(session) then return end
        if session ~= state.session then
            -- A child (the program) ended; the root adapter session may
            -- linger. The exit path closes it once the reply is built.
            state.child_ended = true
            wake("exited", { terminated = true })
            return
        end
        session_ended("terminated")
        wake("exited", { terminated = true })
    end
    L.after.launch[key] = function(session, e)
        if e and (our_session(session) or state.claiming) then
            state.session = state.session or session
            state.claiming = false
            state.launch_error = tostring(e.message or e)
            local body = e.body and e.body.error
            if body and body.format then
                state.launch_error = state.launch_error .. ": " .. body.format
            end
            wake("failed", state.launch_error)
        end
    end
    L.after.attach[key] = L.after.launch[key]
    -- Every OutputEvent lands in the ring buffer, never in the REPL.
    dap.defaults.fallback.on_output = function(session, body)
        if not body or body.category == "telemetry" then return end
        if state.session == nil or our_session(session) then
            local tag = body.category == "stderr" and "" or
                (body.category == "console" and "[adapter] " or "")
            push_output_chunk(body.output, tag)
        end
    end
    -- Sessions the user starts in embedded mode are adopted on demand
    -- (see current_session); nothing to do here beyond noticing ours ended.
    L.on_session[key] = function(old, new)
        if old and our_session(old) and new == nil and state.exit == nil then
            session_ended("closed")
        end
    end

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = vim.api.nvim_create_augroup("agent99_dap_exit", { clear = true }),
        callback = function()
            pcall(M.shutdown_sync, 3000)
        end,
    })
end

------------------------------------------------------------------------
-- Adapter processes this module spawns (Delve)
------------------------------------------------------------------------

local function kill_adapter_proc(signal)
    local h = state.adapter_proc
    if h and not h:is_closing() then
        pcall(h.kill, h, signal or "sigterm")
    end
end

-- Spawn `cmd args` and call `on_ready(host, port)` once its stdout prints
-- a line matching `ready_pattern` with the address. stderr and any other
-- stdout go to the ring buffer under `tag`.
local function spawn_server_adapter(cmd, args, cwd, ready_pattern, tag, on_ready, on_fail)
    local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)
    local ready = false
    local handle
    handle = uv.spawn(cmd, {
        args = args, cwd = cwd, stdio = { nil, stdout, stderr },
    }, function(code)
        vim.schedule(function()
            if handle == state.adapter_proc then state.adapter_proc = nil end
            if not ready then
                on_fail(("%s exited with code %s before it was ready: %s"):format(
                    vim.fn.fnamemodify(cmd, ":t"), tostring(code),
                    table.concat(state.adapter_stderr, " | ")))
            end
        end)
        pcall(stdout.close, stdout)
        pcall(stderr.close, stderr)
        pcall(handle.close, handle)
    end)
    if not handle then
        on_fail("could not start " .. cmd)
        return
    end
    state.adapter_proc = handle
    state.adapter_stderr = {}
    stdout:read_start(function(_, data)
        if not data then return end
        for line in data:gmatch("[^\n]+") do
            local addr = line:match(ready_pattern)
            if addr and not ready then
                ready = true
                local host, port = addr:match("^(.-):(%d+)$")
                vim.schedule(function() on_ready(host, tonumber(port)) end)
            else
                vim.schedule(function() push_output(line, tag) end)
            end
        end
    end)
    stderr:read_start(function(_, data)
        if not data then return end
        vim.schedule(function()
            for line in data:gmatch("[^\n]+") do
                local se = state.adapter_stderr
                se[#se + 1] = line
                if #se > 20 then table.remove(se, 1) end
                push_output(line, tag)
            end
        end)
    end)
end

------------------------------------------------------------------------
-- Built-in adapters
------------------------------------------------------------------------

local function exe(name)
    local p = vim.fn.exepath(name)
    if p ~= "" then return p end
    local mason = vim.fn.stdpath("data") .. "/mason/bin/" .. name
    if vim.fn.executable(mason) == 1 then return mason end
    return nil
end

local function file_exists(p)
    return p and uv.fs_stat(p) ~= nil
end

-- A python that can import debugpy: the project's venv first, then the
-- system interpreter, then Mason's private venv for the debugpy package.
local debugpy_cache = {}
local function debugpy_python(root)
    local cached = debugpy_cache[root or ""]
    if cached ~= nil then return cached or nil end
    local candidates = {}
    for _, venv in ipairs({ ".venv", "venv", "env" }) do
        candidates[#candidates + 1] = (root or ".") .. "/" .. venv .. "/bin/python"
    end
    candidates[#candidates + 1] = vim.fn.exepath("python3")
    candidates[#candidates + 1] = vim.fn.exepath("python")
    candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/mason/packages/debugpy/venv/bin/python"
    local found = false
    for _, py in ipairs(candidates) do
        if py ~= "" and vim.fn.executable(py) == 1 then
            vim.fn.system({ py, "-c", "import debugpy" })
            if vim.v.shell_error == 0 then
                found = py
                break
            end
        end
    end
    debugpy_cache[root or ""] = found
    return found or nil
end

-- The interpreter the debuggee runs under: the project's venv when it
-- has one, else the same python the adapter uses.
local function project_python(root, adapter_py)
    for _, venv in ipairs({ ".venv", "venv", "env" }) do
        local py = root .. "/" .. venv .. "/bin/python"
        if vim.fn.executable(py) == 1 then return py end
    end
    -- The adapter's interpreter may be Mason's private venv, which has
    -- debugpy and nothing else; the program should run under the machine's
    -- python (the adapter injects debugpy into whichever interpreter runs).
    local system = vim.fn.exepath("python3")
    if system ~= "" then return system end
    return adapter_py
end
local BUILTIN = {}

BUILTIN.delve = {
    name = "delve",
    filetypes = { "go" },
    install = { mason = "delve", manual = "go install github.com/go-delve/delve/cmd/dlv@latest" },
    find = function(_) return exe("dlv") end,
    adapter = function(dlv, root)
        return function(callback, config)
            spawn_server_adapter(dlv, { "dap", "-l", "127.0.0.1:0" }, config.cwd or root,
                "DAP server listening at: (%S+)", "[dlv] ",
                function(host, port)
                    callback({ type = "server", host = host, port = port })
                end,
                function(why)
                    state.launch_error = why
                    wake("failed", why)
                end)
        end
    end,
    launch = function(args, root)
        local program = args.program
        if not program and args.file then
            program = vim.fn.fnamemodify(args.file, ":h")
        end
        if not program then
            err(
            "debug_launch for Go needs file (a file in the package to run) or program (package directory or built binary)")
        end
        local cfg = {
            request = "launch",
            name = "agent99",
            program = program,
            cwd = args.cwd or root,
            args = args.args,
            env = args.env,
            stopOnEntry = args.stop_on_entry or false,
            -- The debuggee's stdout/stderr arrive as OutputEvents instead
            -- of landing on Delve's own stdout, so replies tell them apart.
            outputMode = "remote",
        }
        local st = uv.fs_stat(program)
        if st and st.type == "file" and vim.fn.fnamemodify(program, ":e") ~= "go" then
            cfg.mode = "exec"
        else
            cfg.mode = "debug"
        end
        return cfg
    end,
    attach = function(args)
        if args.pid then
            return { request = "attach", name = "agent99", mode = "local", processId = args.pid }
        end
        return { request = "attach", name = "agent99", mode = "remote" }
    end,
    hint = "run the target under a debug server instead: dlv exec --headless --accept-multiclient "
        .. "--listen 127.0.0.1:PORT ./binary, then debug_attach(host, port)",
}

BUILTIN.debugpy = {
    name = "debugpy",
    filetypes = { "python" },
    install = { mason = "debugpy", manual = "pip install debugpy (into the project's interpreter)" },
    find = function(root) return debugpy_python(root) end,
    adapter = function(py)
        return { type = "executable", command = py, args = { "-m", "debugpy.adapter" } }
    end,
    launch = function(args, root, py)
        local program = args.program or args.file
        if not program then
            err("debug_launch for Python needs file (the script to run) or program")
        end
        return {
            request = "launch",
            name = "agent99",
            program = program,
            python = project_python(root, py),
            cwd = args.cwd or root,
            args = args.args,
            env = args.env,
            console = "internalConsole",
            stopOnEntry = args.stop_on_entry or false,
            justMyCode = false,
        }
    end,
    attach = function(args)
        if args.pid then
            return { request = "attach", name = "agent99", processId = args.pid, justMyCode = false }
        end
        return {
            request = "attach",
            name = "agent99",
            connect = { host = args.host or "127.0.0.1", port = args.port },
            justMyCode = false
        }
    end,
    hint = "start the target with python -m debugpy --listen 127.0.0.1:PORT --wait-for-client script.py, "
        .. "then debug_attach(host, port)",
    -- debugpy sends every attach/launch through a server it spawns; the
    -- host/port form connects to it directly.
    remote_adapter = function(args)
        return { type = "server", host = args.host or "127.0.0.1", port = args.port }
    end,
}

-- Native code: codelldb when present (Mason ships it), else lldb-dap, else
-- gdb's own DAP mode (gdb >= 14).
local function native_launch(args, root)
    local program = args.program
    if not program then
        err("debug_launch for native code needs program (the built binary); file alone only picks the adapter")
    end
    return {
        request = "launch",
        name = "agent99",
        program = program,
        cwd = args.cwd or root,
        args = args.args or {},
        env = args.env,
        stopOnEntry = args.stop_on_entry or false,
    }
end

BUILTIN.codelldb = {
    name = "codelldb",
    filetypes = { "c", "cpp", "rust", "zig" },
    install = { mason = "codelldb", manual = "download codelldb from https://github.com/vadimcn/codelldb/releases" },
    find = function(_) return exe("codelldb") end,
    adapter = function(bin)
        return {
            type = "server",
            port = "${port}",
            executable = { command = bin, args = { "--port", "${port}" } },
        }
    end,
    launch = native_launch,
    attach = function(args)
        if args.pid then
            return { request = "attach", name = "agent99", pid = args.pid }
        end
        err("codelldb attaches by pid only; for a remote target use lldb-server and a user nvim-dap configuration")
    end,
    hint = "codelldb attaches by pid; lower /proc/sys/kernel/yama/ptrace_scope or run the target under the debugger",
}

BUILTIN["lldb-dap"] = {
    name = "lldb-dap",
    filetypes = { "c", "cpp", "rust", "zig" },
    install = { manual = "install lldb (the lldb-dap binary ships with it)" },
    find = function(_) return exe("lldb-dap") or exe("lldb-vscode") end,
    adapter = function(bin) return { type = "executable", command = bin } end,
    launch = native_launch,
    attach = function(args)
        if args.pid then
            return { request = "attach", name = "agent99", pid = args.pid }
        end
        err("lldb-dap attaches by pid only")
    end,
    hint = "lldb-dap attaches by pid; lower /proc/sys/kernel/yama/ptrace_scope or run the target under the debugger",
}

BUILTIN.gdb = {
    name = "gdb",
    filetypes = { "c", "cpp", "rust", "zig" },
    install = { manual = "install gdb 14 or newer (it has a built-in DAP mode)" },
    find = function(_)
        local bin = exe("gdb")
        if not bin then return nil end
        local out = vim.fn.system({ bin, "--version" })
        local major = tonumber(out:match("GNU gdb %(.-%) (%d+)") or out:match("GNU gdb (%d+)") or "0")
        if major and major >= 14 then return bin end
        return nil
    end,
    adapter = function(bin)
        return { type = "executable", command = bin, args = { "-q", "-i", "dap" } }
    end,
    launch = function(args, root)
        local cfg = native_launch(args, root)
        cfg.stopAtBeginningOfMainSubprogram = cfg.stopOnEntry
        cfg.stopOnEntry = nil
        return cfg
    end,
    attach = function(args)
        if args.pid then
            return { request = "attach", name = "agent99", pid = args.pid }
        end
        if args.port then
            return {
                request = "attach",
                name = "agent99",
                target = (args.host or "127.0.0.1") .. ":" .. tostring(args.port)
            }
        end
        err("gdb attaches by pid or to a gdbserver at host:port")
    end,
    hint = "gdb attaches by pid; lower /proc/sys/kernel/yama/ptrace_scope or run the target under gdbserver",
}
-- JavaScript and TypeScript: vscode-js-debug, as Mason's js-debug-adapter
-- (node dapDebugServer.js PORT). Its launch config must carry the type
-- "pwa-node", which js-debug reads to pick the debug target, so the
-- adapter is registered under that name rather than an agent99_ one. The
-- program runs in a child session that js-debug opens through a
-- startDebugging reverse request; the listeners follow it (see our_session).
local function js_debug_launcher()
    local mason = vim.fn.stdpath("data") .. "/mason/packages/js-debug-adapter/js-debug/src/dapDebugServer.js"
    if file_exists(mason) and vim.fn.executable("node") == 1 then return mason end
    local bin = exe("js-debug-adapter")
    if bin then return bin end
    return nil
end

BUILTIN["js-debug"] = {
    name = "js-debug",
    dap_type = "pwa-node",
    filetypes = { "javascript", "typescript", "javascriptreact", "typescriptreact" },
    install = {
        mason = "js-debug-adapter",
        manual =
        "download js-debug-dap-*.tar.gz from https://github.com/microsoft/vscode-js-debug/releases and put js-debug-adapter on PATH"
    },
    find = function(_) return js_debug_launcher() end,
    adapter = function(launcher)
        local executable
        if launcher:match("%.js$") then
            executable = { command = vim.fn.exepath("node"), args = { launcher, "${port}" } }
        else
            executable = { command = launcher, args = { "${port}" } }
        end
        return { type = "server", host = "127.0.0.1", port = "${port}", executable = executable }
    end,
    launch = function(args, root)
        local program = args.program or args.file
        if not program then
            err("debug_launch for JavaScript/TypeScript needs file (the script to run) or program")
        end
        return {
            request = "launch",
            name = "agent99",
            program = program,
            cwd = args.cwd or root,
            args = args.args,
            env = args.env,
            console = "internalConsole",
            stopOnEntry = args.stop_on_entry or false,
            skipFiles = { "<node_internals>/**" },
            -- Node 22+ runs .ts files by stripping types, keeping line
            -- numbers, so breakpoints in TypeScript land without a build.
            runtimeExecutable = vim.fn.exepath("node"),
        }
    end,
    attach = function(args)
        if args.pid then
            return { request = "attach", name = "agent99", processId = args.pid }
        end
        return {
            request = "attach",
            name = "agent99",
            address = args.host or "127.0.0.1",
            port = args.port,
            skipFiles = { "<node_internals>/**" }
        }
    end,
    hint = "start the target with node --inspect-brk=127.0.0.1:PORT script.js, then debug_attach(host, port)",
    -- The inspector port is not a DAP port: attach still goes through
    -- js-debug, with the address in the configuration.
    remote_adapter = false,
}

-- Java: Microsoft's java-debug, which is a plugin of the jdtls language
-- server. The adapter asks the running jdtls for a debug port
-- (vscode.java.startDebugSession); launching needs the main class and the
-- classpath, which jdtls resolves too. So jdtls must be attached to the
-- workspace with the java-debug bundle in its init_options - agent99 adds
-- the Mason-installed bundle to the jdtls config when the user set none.
local function java_debug_bundle()
    local dir = vim.fn.stdpath("data") .. "/mason/packages/java-debug-adapter/extension/server"
    local jars = vim.fn.glob(dir .. "/com.microsoft.java.debug.plugin-*.jar", true, true)
    return jars[1]
end

-- Register the bundle with the jdtls config before its client starts.
-- Returns true when the running or future jdtls carries it.
local function ensure_java_bundle()
    local jar = java_debug_bundle()
    if not jar then return false end
    local okc, cfg = pcall(function() return vim.lsp.config.jdtls end)
    if not okc or not cfg then return false end
    local bundles = vim.tbl_get(cfg, "init_options", "bundles") or {}
    for _, b in ipairs(bundles) do
        if b == jar then return true end
    end
    if #bundles > 0 then
        return false -- the user's own list; do not touch it
    end
    pcall(function()
        vim.lsp.config("jdtls", { init_options = { bundles = { jar } } })
    end)
    return true
end
local JDTLS_ATTACH_MS = 90000

-- A jdtls client attached to `file` (or any Java file of the root), waited
-- for because jdtls takes a while to come up.
local function jdtls_client(root, file)
    local lsp = I()
    local sample = file
    if not sample then
        sample = vim.fn.glob(root .. "/**/*.java", true, true)[1]
    end
    if not sample then
        err("no Java file to attach jdtls to under %s", root)
    end
    local bufnr = lsp.load_buf(sample)
    local deadline = now() + JDTLS_ATTACH_MS
    while now() < deadline do
        for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
            if c.name == "jdtls" and c.initialized then
                return c, bufnr
            end
        end
        lsp.sleep(250)
    end
    err("jdtls did not attach to %s within %d s; install_language(\"java\") installs it, "
        .. "and install_debugger(\"java\") adds the java-debug bundle", lsp.rel_path(sample), JDTLS_ATTACH_MS / 1000)
end

local function jdtls_command(client, bufnr, command, arguments)
    local timer = uv.new_timer()
    local rpc_err, result = I().await(function(resume)
        timer:start(60000, 0, vim.schedule_wrap(function()
            resume({ message = "timed out after 60 s" }, nil)
        end))
        local ok = client:request("workspace/executeCommand",
            { command = command, arguments = arguments or {} },
            function(e, r) resume(e, r) end, bufnr)
        if not ok then resume({ message = "failed to send request" }, nil) end
    end)
    timer:stop()
    timer:close()
    if rpc_err then
        local msg = rpc_err.message or vim.inspect(rpc_err)
        if msg:find("not found") or msg:find("No delegateCommandHandler") then
            msg = msg .. " (jdtls is running without the java-debug bundle; restart it after install_debugger(\"java\"))"
        end
        err("jdtls command %s failed: %s", command, msg)
    end
    return result
end

BUILTIN.java = {
    name = "java",
    dap_type = "java",
    filetypes = { "java" },
    install = {
        mason = "java-debug-adapter",
        manual = "install jdtls and the java-debug bundle (Mason: jdtls, java-debug-adapter)"
    },
    find = function(_)
        local jar = java_debug_bundle()
        if not jar then return nil end
        if not exe("jdtls") then return nil end
        ensure_java_bundle()
        return jar
    end,
    adapter = function(_, root)
        return function(callback, config)
            local client = nil
            for _, c in ipairs(vim.lsp.get_clients({ name = "jdtls" })) do
                client = c
            end
            if not client then
                state.launch_error = "no jdtls client is running for " .. root
                wake("failed", state.launch_error)
                return
            end
            client:request("workspace/executeCommand", { command = "vscode.java.startDebugSession", arguments = {} },
                function(e, port)
                    if e or type(port) ~= "number" then
                        state.launch_error = "vscode.java.startDebugSession failed: "
                            .. tostring(e and e.message or port)
                            .. " (is the java-debug bundle in jdtls's init_options.bundles?)"
                        wake("failed", state.launch_error)
                        return
                    end
                    vim.schedule(function()
                        callback({ type = "server", host = "127.0.0.1", port = port })
                    end)
                end, config.__bufnr)
        end
    end,
    launch = function(args, root)
        local client, bufnr = jdtls_client(root, args.file)
        local main_class, project_name = args.program, nil
        if not main_class or main_class:find("/") then
            -- Resolve from the file: jdtls lists the main classes it knows.
            local mains = jdtls_command(client, bufnr, "vscode.java.resolveMainClass", {}) or {}
            local want = args.file and vim.fn.fnamemodify(args.file, ":p") or nil
            for _, m in ipairs(mains) do
                if want == nil or (m.filePath and vim.fn.fnamemodify(m.filePath, ":p") == want) then
                    main_class, project_name = m.mainClass, m.projectName
                    break
                end
            end
            if not main_class then
                local names = {}
                for _, m in ipairs(mains) do names[#names + 1] = m.mainClass end
                err("no main class found%s; jdtls knows: %s (pass program=\"pkg.Main\")",
                    args.file and (" in " .. I().rel_path(args.file)) or "",
                    #names > 0 and table.concat(names, ", ") or "none yet (jdtls may still be indexing; retry)")
            end
        else
            local mains = jdtls_command(client, bufnr, "vscode.java.resolveMainClass", {}) or {}
            for _, m in ipairs(mains) do
                if m.mainClass == main_class then project_name = m.projectName end
            end
        end
        local paths = jdtls_command(client, bufnr, "vscode.java.resolveClasspath", { main_class, project_name })
        local cfg = {
            request = "launch",
            name = "agent99",
            mainClass = main_class,
            projectName = project_name,
            modulePaths = paths and paths[1] or {},
            classPaths = paths and paths[2] or {},
            cwd = args.cwd or root,
            args = args.args and table.concat(args.args, " ") or nil,
            env = args.env,
            console = "internalConsole",
            stopOnEntry = args.stop_on_entry or false,
            __bufnr = bufnr,
        }
        if #cfg.classPaths == 0 and #cfg.modulePaths == 0 then
            err("jdtls resolved no classpath for %s; the project may still be importing, retry in a moment", main_class)
        end
        return cfg
    end,
    attach = function(args, root)
        local _, bufnr = jdtls_client(root, args.file)
        if not args.port then
            err(
            "Java attaches to a JVM started with -agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:PORT; pass host and port")
        end
        return {
            request = "attach",
            name = "agent99",
            hostName = args.host or "127.0.0.1",
            port = args.port,
            __bufnr = bufnr
        }
    end,
    hint =
    "start the JVM with -agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:PORT and debug_attach(host, port)",
    remote_adapter = false,
}
-- Filetype -> ordered candidate adapters.
local BY_FILETYPE = {
    go = { "delve" },
    python = { "debugpy" },
    c = { "codelldb", "lldb-dap", "gdb" },
    cpp = { "codelldb", "lldb-dap", "gdb" },
    rust = { "codelldb", "lldb-dap", "gdb" },
    zig = { "codelldb", "lldb-dap", "gdb" },
    javascript = { "js-debug" },
    typescript = { "js-debug" },
    javascriptreact = { "js-debug" },
    typescriptreact = { "js-debug" },
    java = { "java" },
}

-- Mason package -> built-in spec, for install_debugger.
local PACKAGE_SPEC = {
    delve = "delve",
    debugpy = "debugpy",
    codelldb = "codelldb",
    ["js-debug-adapter"] = "js-debug",
    ["java-debug-adapter"] = "java",
}
local function filetype_of(file)
    if not file then return nil end
    return vim.filetype.match({ filename = file })
end

-- What debugger `ft` has, in one line, for workspace_support and errors.
-- Returns (spec, binary, description).
local function builtin_for(ft, root)
    local names = BY_FILETYPE[ft]
    if not names then
        return nil, nil,
            ("none (no built-in adapter for %s; define dap.adapters/dap.configurations in your Neovim config)"):format(
            ft)
    end
    for _, name in ipairs(names) do
        local spec = BUILTIN[name]
        local bin = spec.find(root)
        if bin then
            return spec, bin, ("%s (built-in, found at %s)"):format(spec.name, bin)
        end
    end
    local first = BUILTIN[names[1]]
    local how = first.install.mason and ("install_debugger(%q)"):format(ft) or first.install.manual
    return nil, nil, ("none (%s or %s)"):format(how, first.install.manual)
end

local function user_configs_for(dap, ft)
    local list = dap.configurations and dap.configurations[ft]
    if type(list) ~= "table" or #list == 0 then return {} end
    return list
end

-- The user's nvim-dap configuration for a filetype, when one exists.
local function user_config_named(dap, ft, name, kind)
    local matches = {}
    for _, c in ipairs(user_configs_for(dap, ft)) do
        if (name == nil or c.name == name) and (kind == nil or c.request == kind) then
            matches[#matches + 1] = c
        end
    end
    return matches
end
-- Evaluate function-valued fields of a user configuration ourselves, with
-- every prompt replaced by an error: headless, a prompt would hang the RPC
-- channel forever.
local function evaluate_user_config(cfg)
    local out = vim.deepcopy(cfg)
    local saved = { vim.fn.input, vim.ui.input, vim.ui.select }
    local function prompt(what)
        return function(...)
            local label = select(1, ...)
            if type(label) == "table" then label = label.prompt end
            error(("configuration %q prompts for %s (%s); pass it as an argument instead")
                :format(cfg.name or "?", tostring(label or what), what), 0)
        end
    end
    vim.fn.input = prompt("input")
    vim.ui.input = prompt("input")
    vim.ui.select = prompt("select")
    local ok, e = pcall(function()
        for k, v in pairs(out) do
            if type(v) == "function" then
                out[k] = v()
            end
        end
    end)
    vim.fn.input, vim.ui.input, vim.ui.select = saved[1], saved[2], saved[3]
    if not ok then err("%s", tostring(e)) end
    return out
end

-- Public description of what can be debugged, for workspace_support.
function M.debugger_for(ft, root)
    local dap = has_dap()
    if not dap then
        if BY_FILETYPE[ft] then
            return "none (" .. NO_DAP .. ")"
        end
        return nil
    end
    local user = user_configs_for(dap, ft)
    if #user > 0 then
        local names = {}
        for _, c in ipairs(user) do
            names[#names + 1] = c.name or "?"
            if #names >= 3 then break end
        end
        return ("%s (user config: %s)"):format(user[1].type or "?", table.concat(names, ", "))
    end
    if not BY_FILETYPE[ft] then
        return nil
    end
    local _, _, desc = builtin_for(ft, root)
    return desc
end
------------------------------------------------------------------------
-- Breakpoint ledger
------------------------------------------------------------------------

local function bp_module()
    return require("dap.breakpoints")
end

local function ledger_find(bufnr, line)
    for i, b in ipairs(state.breakpoints) do
        if b.bufnr == bufnr and b.line == line then return i, b end
    end
    return nil
end

-- nvim-dap's record for a breakpoint (state has id/verified/line after
-- the adapter answered).
local function bp_record(bufnr, line)
    local per_buf = bp_module().get(bufnr)[bufnr] or {}
    for _, bp in ipairs(per_buf) do
        if bp.line == line then return bp end
    end
    return nil
end

local function describe_bp(b, next_id)
    local rec = bp_record(b.bufnr, b.line)
    local out = { file = b.file, line = b.line }
    if b.condition then out.condition = b.condition end
    if b.hit_condition then out.hit_condition = b.hit_condition end
    if b.log_message then out.log_message = b.log_message end
    if rec and rec.state then
        out.id = rec.state.id
        out.verified = rec.state.verified == true
        if rec.state.line and rec.state.line ~= b.line then
            out.requested_line = b.line
            out.line = rec.state.line
        end
        if rec.state.message and rec.state.message ~= "" then out.note = rec.state.message end
    elseif state.session then
        out.verified = false
    else
        out.verified = "pending (sent at launch)"
    end
    if not out.id then out.id = next_id end
    return out
end

local function list_breakpoints()
    local out = {}
    for i, b in ipairs(state.breakpoints) do
        out[#out + 1] = describe_bp(b, i)
    end
    return out
end

-- Send the current breakpoint set to the live session and wait for the
-- adapter's verdict.
-- Every buffer the agent ever placed a breakpoint in, so that a buffer
-- whose last breakpoint was removed still gets an (empty) setBreakpoints:
-- nvim-dap only sends buffers that appear in the table it is given.
local bp_buffers = {}

local function sync_breakpoints(session)
    if not session or session.closed then return end
    local bps = bp_module().get()
    for bufnr in pairs(bp_buffers) do
        if bps[bufnr] == nil and vim.api.nvim_buf_is_valid(bufnr) then
            bps[bufnr] = {}
        end
    end
    if next(bps) == nil then return end
    -- Children (js-debug runs the program in one) need the update too.
    local targets = { session }
    for _, s in ipairs(all_sessions()) do
        if s ~= session then targets[#targets + 1] = s end
    end
    for _, s in ipairs(targets) do
        local timer = uv.new_timer()
        I().await(function(resume)
            timer:start(REQUEST_TIMEOUT_MS, 0, vim.schedule_wrap(function() resume() end))
            local ok = pcall(s.set_breakpoints, s, vim.deepcopy(bps), function() resume() end)
            if not ok then resume() end
        end)
        timer:stop()
        timer:close()
    end
end
-- Remove every breakpoint the agent placed, leaving the user's alone.
local function clear_own_breakpoints()
    for _, b in ipairs(state.breakpoints) do
        pcall(bp_module().remove, b.bufnr, b.line)
    end
    state.breakpoints = {}
end

-- Resolve {file, line | name_path, offset} into (bufnr, path, line).
local function resolve_line(args)
    local lsp = I()
    if args.name_path then
        local bufnr, entry = lsp.resolve_symbol(args.file, args.name_path)
        local offset = tonumber(args.offset) or 1
        local line = entry.first + offset - 1
        if line > entry.last then
            err("offset %d is past the end of %s (%d lines)", offset, entry.path, entry.last - entry.first + 1)
        end
        return bufnr, vim.api.nvim_buf_get_name(bufnr), line
    end
    local line = tonumber(args.line)
    if not line then err("missing required argument: line (or name_path)") end
    local bufnr, path = lsp.load_buf(args.file)
    local count = vim.api.nvim_buf_line_count(bufnr)
    if line < 1 or line > count then
        err("line %d is outside %s (%d lines)", line, args.file, count)
    end
    return bufnr, path, line
end

------------------------------------------------------------------------
-- Reply formatting
------------------------------------------------------------------------

local function clip(s, n)
    s = tostring(s or ""):gsub("%s+", " ")
    n = n or VALUE_CLIP
    if #s > n then return s:sub(1, n - 1) .. "…" end
    return s
end

-- Directories under the root that hold other people's code: frames there
-- are collapsed like frames outside the root.
local VENDORED = {
    "/site%-packages/", "/node_modules/", "/%.venv/", "/venv/", "/vendor/",
    "/third_party/", "/%.cargo/", "/dist%-packages/",
}
local function under_root(path, root)
    if not (path and root and path:sub(1, #root + 1) == root .. "/") then
        return false
    end
    for _, pat in ipairs(VENDORED) do
        if path:find(pat) then return false end
    end
    return true
end
local function render_var(v)
    local val = v.value
    if (val == nil or val == "") and (v.variablesReference or 0) > 0 then
        local n = (v.namedVariables or 0) + (v.indexedVariables or 0)
        val = n > 0 and ("{%d children}"):format(n) or "{…}"
    end
    local s = v.name
    if v.type and v.type ~= "" then s = s .. ": " .. v.type end
    return clip(s .. " = " .. tostring(val))
end

-- debugpy's synthetic groups add nothing an agent wants at a stop.
local NOISE_VARS = {
    ["special variables"] = true,
    ["function variables"] = true,
    ["class variables"] = true,
    ["protected variables"] = true,
    ["__proto__"] = true,
}

-- Names and types no stop reply wants: debugpy's synthetic groups,
-- dunders, bound methods and the "len()" pseudo-entries of containers.
local NOISE_TYPES = {
    method = true,
    ["function"] = true,
    builtin_function_or_method = true,
    ["method-wrapper"] = true,
    ["wrapper_descriptor"] = true,
}
local function is_noise(v)
    local name = tostring(v.name or "")
    if NOISE_VARS[name] then return true end
    if NOISE_TYPES[v.type or ""] then return true end
    if name:match("%(%)$") then return true end
    return name:match("^__.*__$") ~= nil
end
-- Locals and arguments of a frame, one string each, capped.
local function frame_locals(session, frame, max)
    local e, sc = try_request(session, "scopes", { frameId = frame.id })
    if e or not sc then return {}, 0 end
    local lines, total = {}, 0
    for _, scope in ipairs(sc.scopes or {}) do
        local name = (scope.name or ""):lower()
        if not scope.expensive and (name:find("local") or name:find("argument")) then
            local e2, vars = try_request(session, "variables", { variablesReference = scope.variablesReference })
            if not e2 and vars then
                for _, v in ipairs(vars.variables or {}) do
                    if not is_noise(v) then
                        total = total + 1
                        if #lines < max then
                            lines[#lines + 1] = state.variables_mode == "names"
                                and clip(v.name .. (v.type and v.type ~= "" and (": " .. v.type) or ""))
                                or render_var(v)
                        end
                    end
                end
            end
        end
    end
    if total > #lines then
        lines[#lines + 1] = ("+%d more, debug_variables has them"):format(total - #lines)
    end
    return lines, total
end

local function frame_file(frame)
    return frame.source and frame.source.path or nil
end

-- "#3 pkg.Func file.go:12", with runs of frames outside the root collapsed.
local function format_stack(frames, root, max, all_frames)
    local out, ext_run = {}, 0
    local function flush(idx)
        if ext_run > 0 then
            out[#out + 1] = ("#%d-%d <external ×%d>"):format(idx - ext_run, idx - 1, ext_run)
            if ext_run == 1 then out[#out] = ("#%d <external>"):format(idx - 1) end
            ext_run = 0
        end
    end
    local shown = 0
    for i, f in ipairs(frames) do
        local path = frame_file(f)
        local inside = all_frames or under_root(path, root) or path == nil
        if inside then
            flush(i - 1)
            if shown >= max then
                out[#out + 1] = ("+%d more frames, debug_stack(depth=N) shows them"):format(#frames - i + 1)
                return out
            end
            local where = path and (I().rel_path(path) .. ":" .. tostring(f.line)) or "<no source>"
            out[#out + 1] = ("#%d %s %s"):format(i - 1, f.name or "?", where)
            shown = shown + 1
        else
            ext_run = ext_run + 1
        end
    end
    flush(#frames)
    return out
end

local function annotate_frame(frame, root)
    local path = frame_file(frame)
    local info = { file = path, line = frame.line, name = frame.name }
    if not path or not file_exists(path) then
        info.file = path or "<no source>"
        return info, nil
    end
    local lsp = I()
    local okb, bufnr = pcall(lsp.load_buf, path)
    if not okb then return info, nil end
    local entries = lsp.symbol_index(bufnr)
    -- The enclosing function or type, not the variable on that line
    -- (Python's index lists assignments as symbols too).
    local scopes = {}
    for _, entry in ipairs(entries) do
        local kind = tostring(entry.kind or ""):lower()
        if kind:find("function") or kind:find("method") or kind:find("class")
            or kind:find("constructor") or kind:find("struct") or kind:find("impl") then
            scopes[#scopes + 1] = entry
        end
    end
    local e = lsp.innermost_entry(scopes, frame.line) or lsp.innermost_entry(entries, frame.line)
    if e then
        info.symbol = e.path
        info.at = ("%d/%d"):format(frame.line - e.first + 1, e.last - e.first + 1)
    end
    return info, bufnr
end

local function source_window(bufnr, line)
    if not bufnr then return nil end
    local count = vim.api.nvim_buf_line_count(bufnr)
    local first = math.max(1, line - SOURCE_CONTEXT)
    local last = math.min(count, line + SOURCE_CONTEXT)
    local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
    local out = {}
    for i, text in ipairs(lines) do
        local n = first + i - 1
        out[#out + 1] = ("%d:%s %s"):format(n, n == line and " >" or "  ", text)
    end
    return out
end

local function stale_sources()
    local lsp = I()
    local out = {}
    for file, fp in pairs(state.fingerprints) do
        local nowfp = lsp.disk_fingerprint(file)
        if nowfp ~= nil and nowfp ~= fp then
            out[#out + 1] = lsp.rel_path(file)
        end
    end
    table.sort(out)
    if #out == 0 then return nil end
    return out
end

local function tracked_values(session, frame)
    if #state.track == 0 then return nil end
    local out = {}
    for _, expr in ipairs(state.track) do
        local e, r = try_request(session, "evaluate", { expression = expr, frameId = frame.id, context = "watch" })
        if e or not r then
            out[#out + 1] = expr .. " = <not in scope>"
        else
            out[#out + 1] = clip(expr .. " = " .. tostring(r.result))
        end
    end
    return out
end

local function exit_reply()
    local reply = { state = "exited", output_new = output_new() }
    if state.exit then
        reply.exit_code = state.exit.code
        reply.reason = state.exit.reason
    end
    if reply.exit_code == nil then
        -- js-debug reports the code as a line of output, not an event.
        for _, line in ipairs(output_tail(20)) do
            local code = line:match("[Pp]rocess exited with code (%-?%d+)")
            if code then reply.exit_code = tonumber(code) end
        end
    end
    if not state.had_breakpoints and state.request == "launch" then
        reply.note =
        "no breakpoints were set, so the program ran to its end; place one with debug_breakpoint and relaunch with debug_launch()"
    end
    return reply
end
-- Tear the session state down after an exit has been reported once.
local function finish_session()
    if #state.output > 0 then
        last_output = output_tail(OUTPUT_CAP_LINES)
    end
    local keep = {
        config = state.config or state.last_config,
        launch_args = state.launch_args or state.last_launch_args,
        adapter = state.adapter or state.last_adapter,
        dap_type = state.dap_type or state.last_dap_type,
        track = state.track,
        variables_mode = state.variables_mode,
        breakpoints = state.breakpoints,
        -- So a session that is closing but not yet gone from nvim-dap's
        -- table is never adopted as a "user" session by the next call.
        finished = state.session or state.finished,
    }
    kill_adapter_proc("sigterm")
    state = new_state()
    state.last_config = keep.config
    state.last_launch_args = keep.launch_args
    state.last_adapter = keep.adapter
    state.last_dap_type = keep.dap_type
    state.track = keep.track
    state.variables_mode = keep.variables_mode
    state.finished = keep.finished
    -- Breakpoints stay in nvim-dap's store and in the ledger for relaunch.
    state.breakpoints = keep.breakpoints
end
-- The stop reply shared by launch/attach/continue/step/wait.
local function stop_reply(session, root)
    local stop = state.stop or {}
    local thread_id = stop.threadId
    local reply = { state = "stopped", reason = stop.reason or "unknown", thread = thread_id }
    if not thread_id then
        reply.output_new = output_new()
        return reply
    end
    local e_threads, threads = try_request(session, "threads", {})
    if not e_threads and threads and threads.threads then
        reply.threads = #threads.threads
    end
    local e, st = try_request(session, "stackTrace", { threadId = thread_id, startFrame = 0, levels = 20 })
    if e or not st or not st.stackFrames or #st.stackFrames == 0 then
        reply.note = "no stack frames available" .. (e and (": " .. tostring(e)) or "")
        reply.output_new = output_new()
        return reply
    end
    local frames = st.stackFrames
    local top = frames[1]
    local info, bufnr = annotate_frame(top, root)
    reply.frame = info
    reply.source = source_window(bufnr, top.line)
    if state.variables_mode ~= "none" then
        reply.locals = frame_locals(session, top, LOCALS_MAX)
    end
    reply.stack = format_stack(frames, root, STACK_MAX, false)
    if stop.hitBreakpointIds and #stop.hitBreakpointIds > 0 then
        reply.hit = { id = stop.hitBreakpointIds[1], file = info.file, line = top.line }
    end
    if stop.reason == "exception" then
        reply.exception = { text = stop.text, description = stop.description }
        local e2, ex = try_request(session, "exceptionInfo", { threadId = thread_id })
        if not e2 and ex then
            reply.exception.text = reply.exception.text or ex.exceptionId
            reply.exception.description = reply.exception.description or ex.description
        end
    end
    reply.tracked = tracked_values(session, top)
    reply.output_new = output_new()
    reply.stale_source = stale_sources()
    if reply.stale_source then
        reply.note =
        "source edited since launch: the running program no longer matches it; debug_launch() with no arguments relaunches with breakpoints kept"
    end
    state.current_frame_id = top.id
    state.current_thread = thread_id
    return reply
end

local function running_reply(note)
    local reply = {
        state = "running",
        since_ms = state.started and (now() - state.started) or nil,
        output_new = output_new()
    }
    reply.note = note or
    "the program is still running; debug_wait waits for the next stop, debug_wait(pause_after=true) interrupts it"
    return reply
end

-- Turn a wait_event outcome into the reply for it.
local function outcome_reply(kind, root, timeout_note)
    if kind == "stopped" then
        return stop_reply(active_session(), root)
    elseif kind == "exited" then
        -- `terminated` follows `exited` a moment later and closes the
        -- session; give it that moment so nothing sees a half-dead one.
        local s = state.session
        local deadline = now() + 1500
        while s and not s.closed and now() < deadline do
            I().sleep(50)
        end
        if s and not s.closed then
            -- The program is gone but the root adapter session lingers
            -- (js-debug keeps its parent open): end it ourselves.
            pcall(function()
                s.adapter.options = { disconnect_timeout_sec = 1 }
                s:disconnect({ terminateDebuggee = true }, function() end)
            end)
            deadline = now() + 1500
            while not s.closed and now() < deadline do
                I().sleep(50)
            end
            if not s.closed then pcall(s.close, s) end
        end
        local reply = exit_reply()
        finish_session()
        return reply
    elseif kind == "failed" then
        local why = state.launch_error or "adapter failure"
        local tail = output_tail(10)
        M.shutdown()
        err("%s failed: %s%s", state.request or "launch", why,
            #tail > 0 and ("\nadapter output: " .. table.concat(tail, " | ")) or "")
    end
    return running_reply(timeout_note)
end
------------------------------------------------------------------------
-- Session access
------------------------------------------------------------------------

-- The session the tools act on: ours, or one the user started (embedded
-- mode) which is adopted on first use.
local function current_session(dap)
    if state.session then
        if state.session.closed and state.exit == nil then
            session_ended("closed")
        end
        return state.session
    end
    local s = dap.session()
    if s and not s.closed and s ~= state.finished then
        install_listeners(dap)
        state.session = s
        state.origin = "user"
        state.request = s.config and s.config.request or "launch"
        state.adapter = s.config and s.config.type or "?"
        state.config = s.config
        state.started = now()
        touch()
        if s.stopped_thread_id then
            state.stop = { reason = "pause", threadId = s.stopped_thread_id }
        end
        return s
    end
    return nil
end

local function availability_line(root)
    local parts = {}
    for _, ft in ipairs({ "go", "python", "c" }) do
        local _, _, desc = builtin_for(ft, root)
        parts[#parts + 1] = ft .. ": " .. desc
    end
    return table.concat(parts, "; ")
end

local function need_session(dap, root)
    if dap.sessions and vim.tbl_count(dap.sessions()) > 1 and state.session == nil then
        err("more than one debug session is active in this Neovim; agent99 operates on a single session")
    end
    local s = current_session(dap)
    if not s then
        err("no debug session: start one with debug_launch or debug_attach (%s)", availability_line(root))
    end
    if state.exit ~= nil or s.closed then
        local reply = exit_reply()
        finish_session()
        return nil, reply
    end
    touch()
    return active_session()
end

------------------------------------------------------------------------
-- Idle watchdog
------------------------------------------------------------------------

local function ensure_idle_timer()
    if idle_timer then return end
    idle_timer = uv.new_timer()
    idle_timer:start(IDLE_CHECK_MS, IDLE_CHECK_MS, vim.schedule_wrap(function()
        local s = state.session
        if not s or s.closed or state.origin ~= "agent" or state.waiter then return end
        local idle = options().idle_ms
        if state.last_used and now() - state.last_used > idle then
            local ok = pcall(function()
                s.adapter.options = { disconnect_timeout_sec = 1 }
                s:disconnect({ terminateDebuggee = true })
            end)
            state.exit = { reason = ("idle timeout after %d min"):format(math.floor(idle / 60000)) }
            if not ok then pcall(s.close, s) end
        end
    end))
end

------------------------------------------------------------------------
-- Starting sessions
------------------------------------------------------------------------

local function record_fingerprints(file)
    local lsp = I()
    state.fingerprints = {}
    if file and file_exists(file) then
        state.fingerprints[file] = lsp.disk_fingerprint(file)
    end
    for _, b in ipairs(state.breakpoints) do
        if file_exists(b.file) then
            state.fingerprints[b.file] = lsp.disk_fingerprint(b.file)
        end
    end
end

local function session_options(args)
    local mode = args.variables
    if mode ~= nil and mode ~= "summary" and mode ~= "names" and mode ~= "none" then
        err("variables must be one of summary, names, none")
    end
    state.variables_mode = mode or state.variables_mode or "summary"
    if args.track ~= nil then
        if type(args.track) ~= "table" then err("track must be a list of expressions") end
        state.track = args.track
    end
end

-- Start `config` with `adapter` and wait for the first stop or exit.
local function start_session(dap, adapter_name, adapter, config, args, root, request_kind, dap_type)
    if state.session and not state.session.closed and state.exit == nil then
        err(
            "a debug session is already active (%s, %s); debug_stop it first, or debug_launch() with no arguments to restart",
            state.adapter or "?", state.request or "?")
    end
    install_listeners(dap)
    ensure_idle_timer()
    local keep_bps = state.breakpoints
    local keep_track, keep_mode = state.track, state.variables_mode
    local keep_last = { state.last_config, state.last_launch_args, state.last_adapter, state.last_dap_type }
    state = new_state()
    state.breakpoints = keep_bps
    state.track, state.variables_mode = keep_track, keep_mode
    state.last_config, state.last_launch_args = keep_last[1], keep_last[2]
    state.last_adapter, state.last_dap_type = keep_last[3], keep_last[4]
    session_options(args)
    state.origin = "agent"
    state.request = request_kind
    state.adapter = adapter_name
    state.config = config
    state.launch_args = args
    state.started = now()
    state.had_breakpoints = #state.breakpoints > 0
    touch()
    record_fingerprints(args.file)

    -- Built-ins register under a private name; adapters that read the
    -- configuration's type themselves (js-debug's "pwa-node", java) and
    -- user configurations keep theirs, reusing an adapter the user defined.
    local type_name = dap_type or ("agent99_" .. adapter_name)
    if not dap_type or dap.adapters[type_name] == nil then
        dap.adapters[type_name] = adapter
    end
    dap.defaults[type_name].auto_continue_if_many_stopped = false
    config = vim.deepcopy(config)
    config.type = type_name
    config.request = request_kind
    config.name = config.name or "agent99"
    state.dap_type = type_name
    state.claiming = true
    local wait_ms = clamp_wait(args.wait_ms)
    local ok_run, run_err = pcall(dap.run, config, { new = true })
    if not ok_run then
        state.claiming = false
        err("could not start the adapter: %s", tostring(run_err))
    end
    -- Phase 1: the adapter must come up and send `initialized` within
    -- ADAPTER_START_MS, whatever the caller's wait; a missing binary or a
    -- wrong version shows up here, with the adapter's own output.
    local tool = "debug_" .. request_kind
    local kind = wait_event(tool, ADAPTER_START_MS)
    if kind == "timeout" then
        local tail = table.concat(output_tail(10), " | ")
        M.shutdown()
        err("the %s adapter did not initialize within %d s%s", adapter_name,
            ADAPTER_START_MS / 1000, tail ~= "" and (": " .. tail) or "")
    end
    -- Phase 2: the first stop or exit, within the caller's wait.
    if kind == "initialized" then
        kind = wait_event(tool, wait_ms)
    end
    local reply = outcome_reply(kind, root,
        "the program is running (no breakpoint hit yet); debug_wait waits for a stop")
    reply.adapter = adapter_name
    reply.request = request_kind
    reply.program = config.program
    if state.session or reply.state == "exited" then
        reply.breakpoints = list_breakpoints()
    end
    if #state.track > 0 then reply.track = state.track end
    return reply
end

local function pick_adapter(dap, args, root, request_kind)
    local ft = args.adapter and BY_FILETYPE[args.adapter] and args.adapter or nil
    ft = ft or filetype_of(args.file) or filetype_of(args.program)
    if args.adapter and BUILTIN[args.adapter] then
        local spec = BUILTIN[args.adapter]
        local bin = spec.find(root)
        if not bin then
            err("adapter %s is not installed: %s", args.adapter,
                spec.install.mason and ("install_debugger(%q) or %s"):format(spec.filetypes[1], spec.install.manual)
                or spec.install.manual)
        end
        return spec, bin, ft
    end
    if args.adapter and not BUILTIN[args.adapter] then
        err("unknown adapter %q; built-ins: delve, debugpy, codelldb, lldb-dap, gdb", args.adapter)
    end
    if not ft then
        err(
        "cannot pick a debugger: pass file (its filetype picks the adapter), adapter, or config (a user nvim-dap configuration name)")
    end
    local spec, bin, desc = builtin_for(ft, root)
    if not spec then
        err("no debugger for %s: %s", ft, desc)
    end
    return spec, bin, ft
end

local function launch(args)
    local dap = need_dap()
    local root = args.root or vim.fn.getcwd()
    local relaunch = args.again or (args.file == nil and args.program == nil and args.config == nil)
    if relaunch then
        local cfg = state.config or state.last_config
        local prev = state.launch_args or state.last_launch_args or {}
        if not cfg then
            err("nothing to relaunch: no previous debug_launch in this workspace")
        end
        if state.session and not state.session.closed and state.exit == nil then
            M.shutdown()
        end
        local merged = vim.tbl_extend("force", prev, { wait_ms = args.wait_ms, again = nil })
        for _, k in ipairs({ "variables", "track" }) do
            if args[k] ~= nil then merged[k] = args[k] end
        end
        local adapter_name = state.adapter or state.last_adapter
        local dap_type = state.dap_type or state.last_dap_type
        local adapter = dap.adapters[dap_type or ("agent99_" .. adapter_name)]
        if type(adapter) == "nil" then
            err("the previous adapter (%s) is gone; pass file or program again", adapter_name)
        end
        return start_session(dap, adapter_name, adapter, cfg, merged, root, cfg.request or "launch", dap_type)
    end
    -- A user configuration by name (or the first launch entry for the file).
    local ft = filetype_of(args.file) or filetype_of(args.program)
    if args.config or (ft and #user_config_named(dap, ft, nil, "launch") > 0 and not args.adapter) then
        local candidates = user_config_named(dap, ft, args.config, args.config and nil or "launch")
        if #candidates == 0 and args.config then
            -- Search every filetype for the name.
            for _, list in pairs(dap.configurations or {}) do
                for _, c in ipairs(list) do
                    if c.name == args.config then candidates[#candidates + 1] = c end
                end
            end
        end
        if #candidates == 0 then
            err("no nvim-dap configuration named %q", tostring(args.config))
        end
        local cfg = evaluate_user_config(candidates[1])
        for _, k in ipairs({ "program", "args", "cwd", "env" }) do
            if args[k] ~= nil then cfg[k] = args[k] end
        end
        if args.stop_on_entry ~= nil then cfg.stopOnEntry = args.stop_on_entry end
        local adapter = dap.adapters[cfg.type]
        if not adapter then
            err("configuration %q references adapter %q which is not defined", cfg.name or "?", tostring(cfg.type))
        end
        return start_session(dap, cfg.type, adapter, cfg, args, root, cfg.request or "launch", cfg.type)
    end
    local spec, bin = pick_adapter(dap, args, root, "launch")
    local cfg = spec.launch(args, root, bin)
    return start_session(dap, spec.name, spec.adapter(bin, root), cfg, args, root, "launch", spec.dap_type)
end

local function attach(args)
    local dap = need_dap()
    local root = args.root or vim.fn.getcwd()
    if not args.pid and not args.port then
        err("debug_attach needs pid, or host and port of a debug server")
    end
    local ft = filetype_of(args.file)
    if args.config then
        local candidates = user_config_named(dap, ft, args.config, "attach")
        if #candidates == 0 then err("no nvim-dap attach configuration named %q", args.config) end
        local cfg = evaluate_user_config(candidates[1])
        local adapter = dap.adapters[cfg.type]
        return start_session(dap, cfg.type, adapter, cfg, args, root, "attach", cfg.type)
    end
    local spec, bin = pick_adapter(dap, args, root, "attach")
    local cfg = spec.attach(args, root)
    local adapter
    if args.port and not args.pid and spec.remote_adapter ~= false then
        -- host/port names a DAP server (Delve's headless server, debugpy's
        -- listener): connect to it directly instead of spawning an adapter.
        adapter = spec.remote_adapter and spec.remote_adapter(args)
            or { type = "server", host = args.host or "127.0.0.1", port = args.port }
    else
        adapter = spec.adapter(bin, root)
    end
    local ok, reply = pcall(start_session, dap, spec.name, adapter, cfg, args, root, "attach", spec.dap_type)
    if not ok then
        local msg = tostring(reply)
        if args.pid and (msg:find("ptrace") or msg:find("Operation not permitted") or msg:find("attach")) then
            local scope = vim.fn.readfile("/proc/sys/kernel/yama/ptrace_scope")
            local extra = ""
            if scope and scope[1] and scope[1] ~= "0" then
                extra = (" (this machine has kernel.yama.ptrace_scope=%s, which forbids attaching to a process that is not a child)")
                :format(scope[1])
            end
            if vim.uv.os_uname().sysname == "Darwin" then
                extra = " (on macOS attaching by pid needs System Integrity Protection relaxed for the debugger)"
            end
            msg = msg .. extra .. "; " .. (spec.hint or "")
        end
        err("%s", msg)
    end
    return reply
end

------------------------------------------------------------------------
-- Stopping
------------------------------------------------------------------------

-- End the session: terminate what we launched, disconnect from what we
-- attached to or the user started. Never raises.
function M.shutdown(force)
    local s = state.session
    local dap = has_dap()
    if not s or not dap then
        kill_adapter_proc("sigterm")
        return { stopped = false }
    end
    local result = { stopped = true }
    if not s.closed then
        local terminate = state.origin == "agent" and state.request == "launch" or force
        pcall(function() s.adapter.options = { disconnect_timeout_sec = 2 } end)
        local timer = uv.new_timer()
        local kind = I().await(function(resume)
            state.waiter = { tool = "debug_stop", since = now(), resume = resume }
            timer:start(STOP_GRACE_MS, 0, vim.schedule_wrap(function()
                if state.waiter and state.waiter.resume == resume then state.waiter = nil end
                resume("timeout")
            end))
            local ok = pcall(function()
                if terminate then
                    if s.capabilities and s.capabilities.supportsTerminateRequest then
                        s:request("terminate", {}, function() end)
                    else
                        s:disconnect({ terminateDebuggee = true }, function() end)
                    end
                else
                    -- A halted attach target stays halted after disconnect
                    -- (Delve documents this); let it run first.
                    if s.stopped_thread_id then
                        s:request("continue", { threadId = s.stopped_thread_id }, function() end)
                    end
                    s:disconnect({ terminateDebuggee = false }, function() end)
                end
            end)
            if not ok then resume("timeout") end
        end)
        timer:stop()
        timer:close()
        if kind == "timeout" and not s.closed then
            result.killed = true
            pcall(s.close, s)
        end
        if terminate and state.exit and state.exit.code ~= nil then
            result.exit_code = state.exit.code
        end
    end
    if state.adapter_proc then
        kill_adapter_proc("sigterm")
        local h = state.adapter_proc
        vim.defer_fn(function()
            if h and not h:is_closing() then pcall(h.kill, h, "sigkill") end
        end, 2000)
    end
    result.output_tail = output_tail(20)
    local origin = state.origin
    finish_session()
    if origin == "agent" then
        clear_own_breakpoints()
    end
    return result
end
-- Same as shutdown, for callers outside a tool coroutine (the bridge's
-- close_workspace and Neovim's own exit): blocks the main loop briefly
-- instead of yielding. Never raises.
function M.shutdown_sync(timeout_ms)
    local s = state.session
    if s and not s.closed then
        local terminate = state.origin == "agent" and state.request == "launch"
        pcall(function() s.adapter.options = { disconnect_timeout_sec = 1 } end)
        pcall(function()
            if terminate then
                if s.capabilities and s.capabilities.supportsTerminateRequest then
                    s:request("terminate", {}, function() end)
                else
                    s:disconnect({ terminateDebuggee = true }, function() end)
                end
            else
                if s.stopped_thread_id then
                    s:request("continue", { threadId = s.stopped_thread_id }, function() end)
                end
                s:disconnect({ terminateDebuggee = false }, function() end)
            end
        end)
        vim.wait(timeout_ms or 3000, function() return s.closed end, 50)
        if not s.closed then pcall(s.close, s) end
    end
    local h = state.adapter_proc
    if h and not h:is_closing() then
        pcall(h.kill, h, "sigterm")
        vim.wait(500, function() return h:is_closing() == true end, 50)
        if not h:is_closing() then pcall(h.kill, h, "sigkill") end
    end
    local origin = state.origin
    finish_session()
    if origin == "agent" then
        clear_own_breakpoints()
    end
end
------------------------------------------------------------------------
-- Tools
------------------------------------------------------------------------

local function debug_launch(args) return launch(args) end
local function debug_attach(args) return attach(args) end

local function debug_stop(args)
    local dap = need_dap()
    local s = current_session(dap)
    if not s then
        clear_own_breakpoints()
        return { stopped = false, note = "no debug session" }
    end
    touch()
    return M.shutdown(args.force == true)
end

local function debug_continue(args)
    local dap = need_dap()
    local root = args.root or vim.fn.getcwd()
    local s, reply = need_session(dap, root)
    if not s then return reply end
    local thread = state.current_thread or s.stopped_thread_id
    if not thread and not state.stop then
        return running_reply("the program is already running; debug_wait waits for the next stop")
    end
    thread = thread or (state.stop and state.stop.threadId)
    local temp_bp
    if args.to then
        local to = args.to
        if type(to) ~= "table" or not to.file then
            err("to must be an object with file and line or name_path")
        end
        local bufnr, path, line = resolve_line(to)
        if not bp_record(bufnr, line) then
            bp_module().set({}, bufnr, line)
            bp_buffers[bufnr] = true
            temp_bp = { bufnr = bufnr, line = line, file = path }
            sync_breakpoints(s)
        end
    end
    state.stop = nil
    request(s, "continue", { threadId = thread })
    local kind = wait_event("debug_continue", clamp_wait(args.wait_ms))
    if temp_bp then
        pcall(bp_module().remove, temp_bp.bufnr, temp_bp.line)
        if state.session and not state.session.closed then sync_breakpoints(state.session) end
    end
    return outcome_reply(kind, root)
end

local STEP_COMMANDS = { over = "next", into = "stepIn", out = "stepOut" }

local function debug_step(args)
    local dap = need_dap()
    local root = args.root or vim.fn.getcwd()
    local s, reply = need_session(dap, root)
    if not s then return reply end
    local command = STEP_COMMANDS[args.action or "over"]
    if not command then err("action must be one of over, into, out") end
    local thread = state.current_thread or s.stopped_thread_id or (state.stop and state.stop.threadId)
    if not thread then
        return running_reply(
        "the program is running, so there is nothing to step; debug_wait(pause_after=true) stops it first")
    end
    local count = math.max(1, math.min(tonumber(args.count) or 1, 50))
    local wait_ms = clamp_wait(args.wait_ms)
    local kind
    for _ = 1, count do
        state.stop = nil
        request(s, command, { threadId = thread, granularity = "statement" })
        kind = wait_event("debug_step", wait_ms)
        if kind ~= "stopped" then break end
        thread = state.stop and state.stop.threadId or thread
    end
    return outcome_reply(kind, root)
end

local function debug_wait(args)
    local dap = need_dap()
    local root = args.root or vim.fn.getcwd()
    local s, reply = need_session(dap, root)
    if not s then return reply end
    local wait_ms = clamp_wait(args.wait_ms)
    if state.stop then
        return stop_reply(s, root)
    end
    local kind = wait_event("debug_wait", wait_ms)
    local pause_note
    if kind == "timeout" and args.pause_after then
        local thread = state.current_thread
        if not thread then
            local e_threads, threads = try_request(s, "threads", {})
            if not e_threads and threads and threads.threads and threads.threads[1] then
                thread = threads.threads[1].id
            end
        end
        local e = select(1, try_request(s, "pause", { threadId = thread or 1 }))
        if not e then
            kind = wait_event("debug_wait", 5000)
            if kind == "timeout" then
                pause_note = "pause was sent but no stop event arrived within 5 s"
            end
        else
            pause_note = "pause failed: " .. tostring(e)
        end
    end
    return outcome_reply(kind, root, pause_note)
end

local function debug_breakpoint(args)
    local dap = need_dap()
    install_listeners(dap)
    if not args.file then err("missing required argument: file") end
    local bufnr, path, line = resolve_line(args)
    local file = path
    if args.remove then
        local idx = ledger_find(bufnr, line)
        if not idx then
            err("no agent breakpoint at %s:%d (the user's breakpoints are left alone)", I().rel_path(file), line)
        end
        table.remove(state.breakpoints, idx)
        pcall(bp_module().remove, bufnr, line)
        local s = state.session
        if s and not s.closed then sync_breakpoints(s) end
        return { removed = true, file = file, line = line }
    end
    local opts = {}
    if args.condition then opts.condition = args.condition end
    if args.hit_condition then opts.hit_condition = args.hit_condition end
    if args.log_message then opts.log_message = args.log_message end
    bp_buffers[bufnr] = true
    bp_module().set({ condition = opts.condition, hit_condition = opts.hit_condition, log_message = opts.log_message },
        bufnr, line)
    local idx, entry = ledger_find(bufnr, line)
    if not entry then
        entry = { bufnr = bufnr, line = line, file = file }
        state.breakpoints[#state.breakpoints + 1] = entry
        idx = #state.breakpoints
    end
    entry.condition, entry.hit_condition, entry.log_message = opts.condition, opts.hit_condition, opts.log_message
    if state.session and state.fingerprints[file] == nil and file_exists(file) then
        state.fingerprints[file] = I().disk_fingerprint(file)
    end
    local s = state.session
    if s and not s.closed then
        touch()
        state.had_breakpoints = true
        sync_breakpoints(s)
    end
    local out = describe_bp(entry, idx)
    out.text = vim.trim(vim.api.nvim_buf_get_lines(bufnr, out.line - 1, out.line, false)[1] or "")
    if out.requested_line then
        out.note = ("the adapter moved the breakpoint from line %d to %d"):format(out.requested_line, out.line)
    end
    return out
end

local function debug_breakpoints(args)
    need_dap()
    if args.clear then
        local n = #state.breakpoints
        clear_own_breakpoints()
        local s = state.session
        if s and not s.closed then sync_breakpoints(s) end
        return { cleared = n }
    end
    return { breakpoints = list_breakpoints(), count = #state.breakpoints }
end

local function frame_for(s, args)
    local thread = args.thread or state.current_thread or s.stopped_thread_id
    if not thread then
        return nil, running_reply("the program is running; debug_wait(pause_after=true) stops it")
    end
    local depth = tonumber(args.depth) or STACK_DEPTH_DEFAULT
    local st = request(s, "stackTrace",
        { threadId = thread, startFrame = 0, levels = math.max(depth, (tonumber(args.frame) or 0) + 1) })
    local frames = st.stackFrames or {}
    local idx = (tonumber(args.frame) or 0) + 1
    local frame = frames[idx]
    if not frame then err("frame %d does not exist (%d frames)", idx - 1, #frames) end
    return frame, nil, frames, thread, st.totalFrames
end

local function debug_stack(args)
    local dap = need_dap()
    local root = args.root or vim.fn.getcwd()
    local s, reply = need_session(dap, root)
    if not s then return reply end
    local thread = args.thread or state.current_thread or s.stopped_thread_id
    if not thread then
        return running_reply("the program is running; debug_wait(pause_after=true) stops it")
    end
    local depth = math.max(1, math.min(tonumber(args.depth) or STACK_DEPTH_DEFAULT, 200))
    local st = request(s, "stackTrace", { threadId = thread, startFrame = 0, levels = depth })
    local frames = st.stackFrames or {}
    local out = { thread = thread, frames = format_stack(frames, root, depth, args.all_frames == true) }
    if st.totalFrames and st.totalFrames > #frames then
        out.truncated = st.totalFrames - #frames
    end
    return out
end

local function debug_variables(args)
    local dap = need_dap()
    local root = args.root or vim.fn.getcwd()
    local s, reply = need_session(dap, root)
    if not s then return reply end
    local frame, running = frame_for(s, args)
    if not frame then return running end
    local max = math.max(1, math.min(tonumber(args.max) or VARIABLES_MAX, 200))
    local depth = math.max(1, math.min(tonumber(args.depth) or 1, 3))
    local out = { frame = (tonumber(args.frame) or 0), variables = {} }
    local lines = out.variables
    local total = 0

    local function walk(ref, prefix, level)
        if ref == 0 or level > depth then return end
        local e, vars = try_request(s, "variables", { variablesReference = ref })
        if e or not vars then return end
        for _, v in ipairs(vars.variables or {}) do
            if (v.name == nil or v.name == "") and (v.variablesReference or 0) > 0 then
                -- A pointer's single unnamed child is the value it points
                -- to (Delve); step through it without spending a level.
                walk(v.variablesReference, prefix, level)
            elseif not is_noise(v) then
                total = total + 1
                if #lines < max then
                    local name = prefix .. tostring(v.name)
                    lines[#lines + 1] = render_var(vim.tbl_extend("force", v, { name = name }))
                    if (v.variablesReference or 0) > 0 and level < depth then
                        walk(v.variablesReference, name .. ".", level + 1)
                    end
                end
            end
        end
    end
    if args.expand then
        local r = request(s, "evaluate", { expression = args.expand, frameId = frame.id, context = "watch" })
        out.expand = args.expand
        lines[#lines + 1] = render_var({
            name = args.expand,
            type = r.type,
            value = r.result,
            variablesReference = r.variablesReference
        })
        walk(r.variablesReference or 0, args.expand .. ".", 1)
    else
        local sc = request(s, "scopes", { frameId = frame.id })
        local want = (args.scope or "locals"):lower()
        for _, scope in ipairs(sc.scopes or {}) do
            local name = (scope.name or ""):lower()
            local is_local = name:find("local") or name:find("argument")
            local is_global = name:find("global") or name:find("static")
            if (want == "locals" and is_local) or (want == "globals" and is_global) or want == "all" then
                if not scope.expensive or want ~= "locals" then
                    walk(scope.variablesReference, "", 1)
                end
            end
        end
    end
    if total > #lines then
        out.truncated = total - #lines
        out.note = "raise max, or expand one path with expand=\"name.field\""
    end
    return out
end

local function debug_evaluate(args)
    local dap = need_dap()
    local root = args.root or vim.fn.getcwd()
    local s, reply = need_session(dap, root)
    if not s then return reply end
    if type(args.expression) ~= "string" or args.expression == "" then
        err("missing required argument: expression")
    end
    local frame, running = frame_for(s, args)
    if not frame then return running end
    local r = request(s, "evaluate", {
        expression = args.expression,
        frameId = frame.id,
        -- gdb's "repl" context runs CLI commands ("x * 10" examines memory).
        context = args.context or (state.adapter == "gdb" and "watch" or "repl")
    })
    local out = { result = clip(r.result, 400), type = r.type }
    if (r.variablesReference or 0) > 0 then
        out.children = (r.namedVariables or 0) + (r.indexedVariables or 0)
        if out.children == 0 then out.children = nil end
        out.note = ("structured value; debug_variables(expand=%q) lists its fields"):format(args.expression)
    end
    return out
end

local function debug_output(args)
    local tail = math.max(1, math.min(tonumber(args.tail) or 100, OUTPUT_TAIL_MAX))
    local source = #state.output > 0 and state.output or (last_output or {})
    local lines = {}
    if args.grep and args.grep ~= "" then
        local ok, re = pcall(vim.regex, args.grep)
        for _, l in ipairs(source) do
            local hit = ok and re:match_str(l) ~= nil or (not ok and l:find(args.grep, 1, true) ~= nil)
            if hit then lines[#lines + 1] = l end
        end
    else
        for _, l in ipairs(source) do lines[#lines + 1] = l end
    end
    local total = #lines
    if #lines > tail then
        local cut = {}
        for i = #lines - tail + 1, #lines do cut[#cut + 1] = lines[i] end
        lines = cut
    end
    local out = { lines = lines, total = total }
    if #state.output == 0 and last_output then
        out.note = "from the previous session (no session is active)"
    end
    if state.output_dropped > 0 then
        out.dropped = state.output_dropped
    end
    if state.session then
        state.output_cursor = #state.output
    end
    return out
end

local DEBUGGER_PACKAGES = {
    go = "delve",
    python = "debugpy",
    c = "codelldb",
    cpp = "codelldb",
    rust = "codelldb",
    zig = "codelldb",
    javascript = "js-debug-adapter",
    typescript = "js-debug-adapter",
    javascriptreact = "js-debug-adapter",
    typescriptreact = "js-debug-adapter",
    java = "java-debug-adapter",
}
local function install_debugger(args)
    local ft = args.language
    if type(ft) ~= "string" or ft == "" then err("missing required argument: language") end
    ft = vim.filetype.match({ filename = "x." .. ft:lower() }) or ft:lower()
    local root = args.root or vim.fn.getcwd()
    local package = args.package or DEBUGGER_PACKAGES[ft]
    if not package then
        err("no known debug adapter package for %s; pass package explicitly", ft)
    end
    local spec = BUILTIN[PACKAGE_SPEC[package] or package] or BUILTIN.codelldb
    local out = { language = ft, package = package }
    local already = spec.find and spec.find(root)
    if already then
        out.status = "already installed"
        out.binary = already
        return out
    end
    local okreg, registry = pcall(require, "mason-registry")
    if not okreg then
        out.status = "skipped"
        out.note = "mason.nvim is needed to install debug adapters; by hand: " .. spec.install.manual
        return out
    end
    local pkg
    local okp = pcall(function() pkg = registry.get_package(package) end)
    if not okp or not pkg then
        I().await(function(resume) pcall(registry.refresh, function() resume() end) end)
        okp = pcall(function() pkg = registry.get_package(package) end)
    end
    if not okp or not pkg then
        out.status = "unknown"
        out.note = "Mason registry has no package " .. package .. "; by hand: " .. spec.install.manual
        return out
    end
    if not pkg:is_installed() then
        local timer = uv.new_timer()
        local timed_out = I().await(function(resume)
            timer:start(8 * 60 * 1000, 0, vim.schedule_wrap(function() resume(true) end))
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
            out.note = "install did not finish within 8 minutes"
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
    else
        out.status = "already installed"
    end
    debugpy_cache = {}
    local bin = spec.find and spec.find(root)
    out.binary = bin
    if not bin then
        out.note = "installed, but the adapter binary is not visible from this Neovim (Mason's bin dir on PATH?)"
    end
    return out
end

local dispatch_table = {
    debug_launch = debug_launch,
    debug_attach = debug_attach,
    debug_breakpoint = debug_breakpoint,
    debug_breakpoints = debug_breakpoints,
    debug_continue = debug_continue,
    debug_step = debug_step,
    debug_wait = debug_wait,
    debug_stack = debug_stack,
    debug_variables = debug_variables,
    debug_evaluate = debug_evaluate,
    debug_output = debug_output,
    debug_stop = debug_stop,
    install_debugger = install_debugger,
}

function M.handles(tool)
    return dispatch_table[tool] ~= nil
end

function M.dispatch(tool, args)
    local fn = dispatch_table[tool]
    if not fn then err("unknown tool: %s", tostring(tool)) end
    return fn(args or {})
end

-- For tests.
M._state = function() return state end

return M
