-- run_tests: the project's test suite as a tool, so the edit-check-test loop
-- stays inside agent99 instead of falling back to a shell for the last
-- step. It knows the common runners, remembers the command per root the way
-- check_project does, turns the output into failures with a file and line,
-- names the test symbol each failure sits in, and diffs against a baseline
-- keyed by test name so a rerun answers "what broke and what got fixed"
-- rather than replaying a page of output.

local M = {}

local core = require("agent99.core")
local index = require("agent99.index")
local install = require("agent99.install")
local err, await, rel_path, load_buf = core.err, core.await, core.rel_path, core.load_buf

local OUTPUT_MAX_LINES = 80
local FAILURES_MAX = 40

-- Commands remembered per root, shared with later sessions.
local test_override, save_test_override = install.command_store("test_commands")

-- Baselines per root and command: the failing test names (or, when nothing
-- parsed as a test, the output lines) of the last run.
local baselines = {}

local function exists(root, name)
    return vim.fn.filereadable(root .. "/" .. name) == 1
end

local function shell_quote(s)
    return vim.fn.shellescape(s)
end

-- The runner this project most likely uses, with the path and filter woven
-- in where the runner has a way to take them. The project's own definition
-- (a Makefile test target) beats the language default, because it is what
-- CI runs.
local function guess_test_command(root, path, filter)
    local guesses = {}
    local rel
    if path then
        rel = path:sub(1, #root + 1) == root .. "/" and path:sub(#root + 2) or rel_path(path)
        -- "." and "./" name the root, which is no narrowing at all: passed
        -- through, they came out as `go test ././...`, and they hid the
        -- Makefile target that a call with no path would have found.
        rel = (rel:gsub("^%./", ""))
        if rel == "." or rel == "" then
            rel, path = nil, nil
        end
    end
    local function add(cmd, runner, note)
        guesses[#guesses + 1] = { cmd = cmd, runner = runner, note = note }
    end
    if not path and not filter and exists(root, "Makefile") then
        local ok, lines = pcall(vim.fn.readfile, root .. "/Makefile")
        if ok then
            for _, l in ipairs(lines) do
                if l:match("^test:") or l:match("^test%s") then
                    add("make test", "make", "the Makefile's test target, whatever it runs")
                    break
                end
            end
        end
    end
    if exists(root, "go.mod") then
        local target = "./..."
        if rel then
            local dir = vim.fn.isdirectory(root .. "/" .. rel) == 1 and rel or vim.fs.dirname(rel)
            target = "./" .. dir .. (vim.fn.isdirectory(root .. "/" .. rel) == 1 and "/..." or "")
        end
        local cmd = "go test " .. target
        if filter then cmd = cmd .. " -run " .. shell_quote(filter) end
        add(cmd, "go")
    end
    if exists(root, "Cargo.toml") then
        local cmd = "cargo test"
        if filter then cmd = cmd .. " " .. shell_quote(filter) end
        if rel then cmd = cmd .. " -- --nocapture" end
        add(cmd, "cargo", rel and "cargo has no path filter; the whole crate ran" or nil)
    end
    if exists(root, "pytest.ini") or exists(root, "conftest.py") or exists(root, "pyproject.toml")
        or exists(root, "setup.cfg") or exists(root, "tox.ini")
        or vim.fn.isdirectory(root .. "/tests") == 1 and #vim.fn.glob(root .. "/tests/test_*.py", true, true) > 0 then
        local runner = vim.fn.executable("pytest") == 1 and "pytest" or "python3 -m pytest"
        local cmd = runner .. " -q -p no:cacheprovider"
        if rel then cmd = cmd .. " " .. shell_quote(rel) end
        if filter then cmd = cmd .. " -k " .. shell_quote(filter) end
        add(cmd, "pytest")
    end
    if exists(root, "package.json") then
        local ok, lines = pcall(vim.fn.readfile, root .. "/package.json")
        local okd, pkg = false, nil
        if ok then okd, pkg = pcall(vim.json.decode, table.concat(lines, "\n")) end
        if okd and type(pkg) == "table" and type(pkg.scripts) == "table" and pkg.scripts.test then
            local pm = "npm"
            if exists(root, "pnpm-lock.yaml") then pm = "pnpm"
            elseif exists(root, "yarn.lock") then pm = "yarn"
            elseif exists(root, "bun.lockb") or exists(root, "bun.lock") then pm = "bun" end
            local cmd = pm .. " test --silent"
            if pm == "npm" then cmd = "npm test --silent --" elseif pm == "pnpm" then cmd = "pnpm test --silent --" end
            if rel then cmd = cmd .. " " .. shell_quote(rel) end
            if filter then cmd = cmd .. " -t " .. shell_quote(filter) end
            add(cmd, "js", ("package.json's test script: %s"):format(pkg.scripts.test))
        end
    end
    if exists(root, ".busted") then
        local cmd = "busted"
        if rel then cmd = cmd .. " " .. shell_quote(rel) end
        if filter then cmd = cmd .. " --filter=" .. shell_quote(filter) end
        add(cmd, "busted")
    end
    return guesses
end

-- Failures out of the runner's output. Each parser is a set of patterns for
-- one runner's conventions; a line that matches none is left in the output.
-- A parsed failure carries test (the name), and file/line/message where the
-- runner printed them.
local function parse_go(lines)
    local failures, current = {}, nil
    for _, l in ipairs(lines) do
        local name = l:match("^%s*%-%-%- FAIL: (%S+)")
        if name then
            current = { test = name }
            failures[#failures + 1] = current
        elseif current then
            local file, line, msg = l:match("^%s+([%w_%-./]+%.go):(%d+): ?(.*)$")
            if file and not current.file then
                current.file, current.line, current.message = file, tonumber(line), msg
                -- testify prints the location on its own line and the detail
                -- under it, so the message came back empty next to an output
                -- that had "expected: 418 / actual: 200" in it.
                if msg == "" then current.want_message = true end
            elseif current.want_message and l:match("%S") then
                current.message = (l:gsub("^%s+", ""):gsub("%s+$", ""))
                current.want_message = nil
            elseif l:match("^FAIL") or l:match("^ok") or l:match("^%-%-%- ") then
                current = nil
            end
        end
    end
    local pkg_fail = {}
    for _, l in ipairs(lines) do
        local pkg = l:match("^FAIL%s+(%S+)%s+%[build failed%]") or l:match("^FAIL%s+(%S+)%s+%[setup failed%]")
        if pkg then pkg_fail[#pkg_fail + 1] = pkg end
    end
    for _, f in ipairs(failures) do
        f.want_message = nil
        if f.message == "" then f.message = nil end
    end
    return failures, pkg_fail
end

local function parse_pytest(lines)
    local failures, by_name = {}, {}
    for _, l in ipairs(lines) do
        local file, name, msg = l:match("^FAILED ([^:]+)::(%S+)%s*%-?%s*(.*)$")
        if not file then file, name = l:match("^ERROR ([^:]+)::(%S+)") end
        if file then
            local f = { test = name, file = file, message = msg ~= "" and msg or nil }
            failures[#failures + 1] = f
            by_name[name:gsub("%[.*$", "")] = f
        end
    end
    -- The traceback's "file:line: Error" line is the line to look at; match
    -- it to the failure whose file it names when the summary gave no line.
    local last_test
    for _, l in ipairs(lines) do
        local underscored = l:match("^_+ (%S+) _+$")
        if underscored then last_test = underscored:gsub("%[.*$", "") end
        local file, line = l:match("^([^:%s]+%.py):(%d+):")
        if file and last_test and by_name[last_test] and not by_name[last_test].line then
            by_name[last_test].line = tonumber(line)
            if not by_name[last_test].file then by_name[last_test].file = file end
        end
    end
    return failures
end

local function parse_js(lines)
    local failures, current = {}, nil
    -- Lua patterns are byte-wise, so a multibyte marker cannot sit in a
    -- character class; try each one.
    local function marked(l)
        for _, mark in ipairs({ "✕", "✗", "×" }) do
            local name = l:match("^%s*" .. mark .. " (.-)%s*$")
            if name then
                return (name:gsub("%s*%(%d+%s*m?s%)$", ""))
            end
        end
        return nil
    end
    for _, l in ipairs(lines) do
        local name = marked(l)
        local detail = l:match("^%s*● (.-)%s*$")
        if name then
            current = nil
            for _, f in ipairs(failures) do if f.test == name then current = f end end
            if not current then
                current = { test = name }
                failures[#failures + 1] = current
            end
        elseif detail and not detail:match("^Test suite failed") then
            -- "● describe › test" repeats a "✕ test" line with its describe
            -- path; keep them as one failure, under the fuller name.
            current = nil
            for _, f in ipairs(failures) do
                local tail = "› " .. f.test
                if f.test == detail or detail:sub(-#tail) == tail then
                    f.test = detail
                    current = f
                end
            end
            if not current then
                current = { test = detail }
                failures[#failures + 1] = current
            end
        elseif current then
            local file, line = l:match("[%(%s]([%w_%-./@]+%.[jt]sx?):(%d+):%d+")
            if file and not current.file and not file:match("node_modules") then
                current.file, current.line = file:gsub("^%./", ""), tonumber(line)
            end
        end
        local suite = l:match("^%s*FAIL%s+(%S+%.[jt]sx?)")
        if suite and current and not current.file then current.file = suite end
    end
    return failures
end

local function parse_cargo(lines)
    local failures, by_name = {}, {}
    for _, l in ipairs(lines) do
        local name = l:match("^test (%S+) %.%.%. FAILED$")
        if name then
            local f = { test = name }
            failures[#failures + 1] = f
            by_name[name] = f
        end
    end
    local current
    for _, l in ipairs(lines) do
        local name = l:match("^%-%-%-%- (%S+) stdout %-%-%-%-$")
        if name then current = by_name[name] end
        local file, line = l:match("panicked at ([%w_%-./]+%.rs):(%d+):%d+")
        if not file then file, line = l:match("^%s*([%w_%-./]+%.rs):(%d+):%d+") end
        if file and current and not current.file then
            current.file, current.line = file, tonumber(line)
            local msg = l:match(":%d+:%d+:%s*(.*)$")
            if msg and msg ~= "" then current.message = msg end
        end
    end
    return failures
end

-- `python -m unittest` prints "FAIL: name (module.Class.name)" and a
-- traceback whose last "File ..., line N" is the assertion. It had no parser
-- at all, so a failing run answered "exit 1; no failures parsed from the
-- output" and the baseline quietly stored every line of output as a failure.
local function parse_unittest(lines)
    local failures, current = {}, nil
    for _, l in ipairs(lines) do
        local kind, name, where = l:match("^(%u+): ([%w_]+) %(([^)]+)%)")
        if kind == "FAIL" or kind == "ERROR" then
            current = { test = name, message = kind == "ERROR" and "error" or nil }
            -- The dotted path names the module the test lives in.
            local module = where:match("^([%w_%.]+)"):gsub("%.[%w_]+$", "")
            current.file = (module:gsub("%.", "/")) .. ".py"
            failures[#failures + 1] = current
        elseif current then
            local file, line = l:match('^%s*File "([^"]+)", line (%d+)')
            if file and not file:match("/unittest/") then
                current.file, current.line = file, tonumber(line)
            end
            local detail = l:match("^(%u%w+Error: .*)$") or l:match("^(AssertionError: .*)$")
            if detail then
                current.message = detail
                current = nil
            end
        end
    end
    return failures
end

-- Whether a run executed no test at all. A filter that matches nothing exits
-- 0 with a note, which read as "all passing" - a typo in filter= was a green
-- verification.
local function ran_nothing(lines)
    -- Evidence that at least one test did run. `go test ./...` prints
    -- "?   pkg [no test files]" for every package without tests, which is
    -- almost every repository: matching that phrase alone reported a whole
    -- passing suite as "no tests ran".
    local ran, none = false, false
    for _, l in ipairs(lines) do
        if l:match("^ok%s+%S") or l:match("^%-%-%- PASS") or l:match("^%-%-%- FAIL")
            or l:match("^PASS") or l:match("^FAIL%s") or l:match("^Ran [1-9]%d* tests?")
            or l:match("%d+ passed") or l:match("%d+ failed") or l:match("^OK$") then
            ran = true
        end
        if l:match("no tests to run") or l:match("^Ran 0 tests") or l:match("NO TESTS RAN")
            or l:match("no tests ran") or l:match("collected 0 items") then
            none = true
        end
    end
    return none and not ran
end

-- A generic sweep for runners without a parser: any "path:line" on a line
-- that also says fail/error/assert, so a failure still gets a location.
local function parse_generic(lines, root, exit_code)
    -- A runner that exited 0 said it passed, and this parser reads prose:
    -- `unittest` printing `ResourceWarning: Implicitly cleaning up
    -- <HTTPError 404>` from the standard library was reported as three
    -- failing tests next to the runner's own "OK". Where a real parser
    -- exists it decides; here the exit code does.
    if exit_code == 0 then
        return {}
    end
    local failures, seen = {}, {}
    -- A prose sweep can match a whole page of output, and the baseline then
    -- stores every line of it as a failing test.
    local GENERIC_MAX = 20
    for _, l in ipairs(lines) do
        if #failures >= GENERIC_MAX then break end
        local lower = l:lower()
        local warning = l:match("%f[%w][%w_]*Warning:%s") ~= nil
        if not warning and (lower:match("fail") or lower:match("error") or lower:match("assert")) then
            local file, line = l:match("([%w_%-./]+%.%a+):(%d+)")
            -- A location in the standard library or in a dependency is where
            -- the failure surfaced, not a test of this project that failed.
            local outside = file ~= nil and file:sub(1, 1) == "/"
                and (root == nil or file:sub(1, #root + 1) ~= root .. "/")
            if file and not outside and not seen[l] then
                seen[l] = true
                failures[#failures + 1] = { test = l:gsub("^%s+", ""), file = file, line = tonumber(line) }
            end
        end
    end
    return failures
end

local function detect_runner(cmd)
    if cmd:match("^go test") then return "go" end
    if cmd:match("pytest") then return "pytest" end
    if cmd:match("^cargo test") then return "cargo" end
    if cmd:match("^npm ") or cmd:match("^pnpm ") or cmd:match("^yarn ") or cmd:match("^bun ")
        or cmd:match("jest") or cmd:match("vitest") or cmd:match("mocha") then
        return "js"
    end
    if cmd:match("busted") then return "busted" end
    if cmd:match("unittest") then return "unittest" end
    return nil
end

local function parse_failures(runner, lines, root, exit_code)
    if runner == "go" then return parse_go(lines) end
    if runner == "pytest" then return parse_pytest(lines) end
    if runner == "js" then return parse_js(lines) end
    if runner == "cargo" then return parse_cargo(lines) end
    if runner == "unittest" then return parse_unittest(lines) end
    -- make and busted: the Makefile's target runs whatever it runs; sniff
    -- the output for the runner it turned out to be.
    for _, l in ipairs(lines) do
        if l:match("^%s*%-%-%- FAIL: ") or l:match("^ok%s+%S+%s+[%d.]+s") then return parse_go(lines) end
        if l:match("^FAILED %S+::") or l:match("^=+ .* passed") then return parse_pytest(lines) end
        if l:match("^test %S+ %.%.%. ") then return parse_cargo(lines) end
        if l:match("^%u+: [%w_]+ %([%w_%.]+%)") or l:match("^Ran %d+ tests? in") then
            return parse_unittest(lines)
        end
        if l:match("^%s*[✕✗×●] ") or l:match("^%s*Tests:%s+%d") then return parse_js(lines) end
    end
    return parse_generic(lines, root, exit_code), nil
end

-- Passed and failed counts from the runner's own summary line, when it
-- prints one; nil where it does not.
local function parse_counts(lines)
    for i = #lines, 1, -1 do
        local l = lines[i]
        local p, f = l:match("(%d+) passed.-(%d+) failed")
        if p then return tonumber(p), tonumber(f) end
        f, p = l:match("(%d+) failed.-(%d+) passed")
        if p then return tonumber(p), tonumber(f) end
        p = l:match("^=+ (%d+) passed")
        if p then return tonumber(p), 0 end
        p, f = l:match("test result: %w+%. (%d+) passed; (%d+) failed")
        if p then return tonumber(p), tonumber(f) end
        p, f = l:match("Tests:%s+(%d+) passed, (%d+) failed")
        if p then return tonumber(p), tonumber(f) end
        f, p = l:match("Tests:%s+(%d+) failed, (%d+) passed")
        if p then return tonumber(p), tonumber(f) end
        p = l:match("^Tests:%s+(%d+) passed, (%d+) total")
        if p then return tonumber(p), 0 end
        p, f = l:match("(%d+) successes? / (%d+) failures?")
        if p then return tonumber(p), tonumber(f) end
    end
    return nil, nil
end

-- The test symbol a failure's file:line sits in, so the reply names what
-- to read (find_symbol name_path) rather than a line to go and look at.
local function annotate(root, failures)
    for _, f in ipairs(failures) do
        if f.file and f.line then
            local path = f.file:sub(1, 1) == "/" and f.file or (root .. "/" .. f.file)
            if vim.fn.filereadable(path) == 1 then
                f.file = path:sub(1, #root + 1) == root .. "/" and path:sub(#root + 2) or rel_path(path)
                local ok, bufnr = pcall(load_buf, path)
                if ok then
                    local oke, entries = pcall(index.symbol_index, bufnr)
                    if oke then
                        local e = index.innermost_entry(entries, f.line)
                        if e then
                            f.symbol = e.path
                            f.symbol_line = f.line - e.first + 1
                        end
                    end
                end
            end
        end
    end
end

local function run_tests(args)
    local root = args.root
    if type(root) ~= "string" or root == "" then
        root = vim.fn.getcwd()
    end
    local okc, config = pcall(require, "agent99.config")
    local post_edit = okc and config.options and config.options.post_edit or {}
    local path = args.path
    if type(path) == "string" and path ~= "" then
        local abs = path:sub(1, 1) == "/" and path or (root .. "/" .. path)
        if vim.fn.filereadable(abs) == 0 and vim.fn.isdirectory(abs) == 0 then
            err("path does not exist: %s", path)
        end
        path = abs
    else
        path = nil
    end
    local filter = type(args.filter) == "string" and args.filter ~= "" and args.filter or nil

    -- Explicit for this call, then the command remembered for this root, then
    -- the environment, the user's config, then the guess. A remembered or
    -- configured command has no place for path= and filter=, so those
    -- fall through to the guess, which does.
    local cmd, explicit, runner, guess_note
    if type(args.command) == "string" and args.command ~= "" then
        cmd, explicit = args.command, true
    elseif not path and not filter then
        cmd = test_override[root] and test_override[root][1]
        local from_env = os.getenv("AGENT99_TEST")
        if not cmd and from_env and from_env ~= "" then cmd = from_env end
        if not cmd and post_edit.test and post_edit.test ~= "" then cmd = post_edit.test end
    end
    local guessed = false
    if not cmd then
        local guesses = guess_test_command(root, path, filter)
        if #guesses == 0 then
            err("no test runner found in %s: pass command= (and remember=true to keep it), "
                .. "set AGENT99_TEST, or post_edit.test in setup()", root)
        end
        cmd, runner, guess_note, guessed = guesses[1].cmd, guesses[1].runner, guesses[1].note, true
        if #guesses > 1 then
            local others = {}
            for i = 2, #guesses do others[#others + 1] = guesses[i].cmd end
            guess_note = (guess_note and (guess_note .. ". ") or "")
                .. "also plausible: " .. table.concat(others, "; ")
        end
    end
    runner = runner or detect_runner(cmd)
    if explicit and args.remember then
        test_override[root] = { cmd }
        save_test_override(root)
    end

    local timeout = post_edit.test_timeout_ms or 10 * 60 * 1000
    local unsaved
    if args.headless then
        local failures = core.save_all()
        if #failures > 0 then unsaved = failures end
    end
    local started = vim.uv.now()
    local result = await(function(resume)
        local ok, e = pcall(vim.system, { "sh", "-c", cmd }, {
            cwd = root, text = true, timeout = timeout,
            env = { CI = "1", NO_COLOR = "1", FORCE_COLOR = "0", TERM = "dumb" },
        }, vim.schedule_wrap(function(r) resume(r) end))
        if not ok then resume({ code = -1, stderr = tostring(e) }) end
    end)
    local text = ((result.stdout or "") .. (result.stderr or "")):gsub("\27%[[%d;]*m", ""):gsub("%s+$", "")
    local lines = text ~= "" and vim.split(text, "\n", { plain = true }) or {}
    local timed_out = result.code == 124 and result.signal == 15

    -- A test run is one more way files appear (generated code, fixtures);
    -- the servers hear of them here rather than at the next edit.
    core.resync_open_buffers()
    local failures, broken = parse_failures(runner, lines, root, result.code)
    annotate(root, failures)
    local passed, failed = parse_counts(lines)
    if failed == nil and #failures > 0 then failed = #failures end

    local out = {
        command = cmd,
        runner = runner,
        guessed = guessed or nil,
        about_this_command = guess_note,
        exit = result.code,
        seconds = math.floor((vim.uv.now() - started) / 100) / 10,
        passed = passed,
        failed = failed,
        unsaved = unsaved,
    }
    if explicit and args.remember then
        out.remembered = "later run_tests calls in this root use this without arguments, "
            .. "in this workspace and in later ones (path= and filter= still fall back to the guess)"
    elseif not explicit and test_override[root] and cmd == test_override[root][1] then
        out.remembered = "using the command remembered for this root"
    end
    if broken and #broken > 0 then
        out.build_failed = broken
    end
    if #failures > FAILURES_MAX then
        out.failures = vim.list_slice(failures, 1, FAILURES_MAX)
        out.failures_truncated = #failures - FAILURES_MAX
    elseif #failures > 0 then
        out.failures = failures
    end

    -- Baseline by test name: a rerun says which tests started failing and
    -- which stopped, and the noise (durations, temp paths) never counts.
    -- Where nothing parsed as a test, the output lines stand in.
    local key = root .. "\0" .. cmd
    local function names_of(list)
        local names = {}
        for _, f in ipairs(list) do names[#names + 1] = f.test end
        return names
    end
    local now_set = #failures > 0 and names_of(failures) or (result.code ~= 0 and lines or {})
    local base = baselines[key]
    if timed_out then
        out.timed_out = true
        out.output = vim.list_slice(lines, 1, OUTPUT_MAX_LINES)
        if #lines > OUTPUT_MAX_LINES then out.output_truncated = #lines - OUTPUT_MAX_LINES end
        out.summary = ("timed out after %g s: the output is partial and no baseline was recorded "
            .. "or compared. Narrow with path= or filter=, or raise post_edit.test_timeout_ms."):format(timeout / 1000)
    elseif base and not args.reset then
        local base_count, now_count = {}, {}
        for _, n in ipairs(base) do base_count[n] = (base_count[n] or 0) + 1 end
        for _, n in ipairs(now_set) do now_count[n] = (now_count[n] or 0) + 1 end
        local new, fixed = {}, {}
        for _, n in ipairs(now_set) do
            if (base_count[n] or 0) > 0 then base_count[n] = base_count[n] - 1 else new[#new + 1] = n end
        end
        for _, n in ipairs(base) do
            if (now_count[n] or 0) > 0 then now_count[n] = now_count[n] - 1 else fixed[#fixed + 1] = n end
        end
        out.baseline_failures = #base
        out.new_failures = new
        out.fixed = fixed
        if result.code == 0 and ran_nothing(lines) then
            out.summary = "no tests ran: the command matched none. A filter that matches nothing "
                .. "exits 0, which is not the same as passing"
        elseif result.code == 0 then
            out.summary = #fixed > 0 and ("all passing; %d fixed since the baseline"):format(#fixed) or "all passing"
        elseif #new == 0 and #fixed == 0 then
            out.summary = ("still failing as at the baseline (%d)"):format(#now_set)
        else
            out.summary = ("%d new failures, %d fixed since the baseline"):format(#new, #fixed)
        end
        if #new > 0 or result.code ~= 0 and #failures == 0 then
            out.output = vim.list_slice(lines, 1, OUTPUT_MAX_LINES)
            if #lines > OUTPUT_MAX_LINES then out.output_truncated = #lines - OUTPUT_MAX_LINES end
        end
        baselines[key] = now_set
    else
        baselines[key] = now_set
        out.baseline = "recorded; later calls report which tests started or stopped failing"
        if result.code ~= 0 or #failures > 0 then
            out.output = vim.list_slice(lines, 1, OUTPUT_MAX_LINES)
            if #lines > OUTPUT_MAX_LINES then out.output_truncated = #lines - OUTPUT_MAX_LINES end
            out.summary = #failures > 0 and ("%d failing"):format(#failures)
                or ran_nothing(lines)
                and ("no tests ran: the command matched none (exit %d). A run that executes no "
                    .. "test is not a passing run"):format(result.code)
                or ("exit %d; no failures parsed from the output, see output"):format(result.code)
        elseif ran_nothing(lines) then
            out.summary = "no tests ran: the command matched none. A filter that matches nothing "
                .. "exits 0, which is not the same as passing"
        else
            out.summary = passed and ("all passing (%d)"):format(passed) or "all passing"
        end
    end
    if #failures > 0 then
        out.next = "each failure names its test symbol; find_symbol(name_path=<symbol>, include_body=true) "
            .. "reads it, and run_tests(filter=<test>) reruns just that one"
    end
    return out
end

M.run_tests = run_tests
M.guess_test_command = guess_test_command
M.parse_failures = parse_failures
M.parse_counts = parse_counts
M.ran_nothing = ran_nothing

return M
