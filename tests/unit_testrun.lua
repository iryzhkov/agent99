-- Unit checks for run_tests' output parsers, driven by canned runner
-- output, since the smoke test cannot count on pytest, jest or cargo being
-- installed. The go parser is exercised for real by drive_headless.py.
--
-- Run with: nvim --clean --headless -u tests/minimal_init.lua -l tests/unit_testrun.lua

local testrun = require("agent99.testrun")

local failures = 0

local function check(name, ok, detail)
    if ok then
        io.stdout:write("ok   " .. name .. "\n")
    else
        failures = failures + 1
        io.stdout:write("FAIL " .. name .. (detail and ("\n     " .. vim.inspect(detail)) or "") .. "\n")
    end
    io.stdout:flush()
end

local function lines(text)
    return vim.split(text, "\n", { plain = true })
end

-- pytest -q: the FAILED summary names the test, the traceback names the line.
local pytest_out = lines([[
F.                                                                       [100%]
=================================== FAILURES ===================================
_______________________________ test_add_negative ______________________________

    def test_add_negative():
>       assert add(-1, 1) == 1
E       assert 0 == 1
E        +  where 0 = add(-1, 1)

tests/test_calc.py:10: AssertionError
=========================== short test summary info ============================
FAILED tests/test_calc.py::test_add_negative - assert 0 == 1
1 failed, 1 passed in 0.02s]])
local f = testrun.parse_failures("pytest", pytest_out)
check("pytest: failure with file, line and message",
    #f == 1 and f[1].test == "test_add_negative" and f[1].file == "tests/test_calc.py"
    and f[1].line == 10 and f[1].message == "assert 0 == 1", f)
local p, fl = testrun.parse_counts(pytest_out)
check("pytest: counts", p == 1 and fl == 1, { p, fl })

-- pytest parametrized ids keep the bracket in the name but match the
-- traceback header without it.
local param_out = lines([[
_____________________________ test_add[2-2-5] _____________________________
tests/test_calc.py:7: AssertionError
FAILED tests/test_calc.py::test_add[2-2-5] - assert 4 == 5
1 failed in 0.01s]])
f = testrun.parse_failures("pytest", param_out)
check("pytest: parametrized id", #f == 1 and f[1].test == "test_add[2-2-5]" and f[1].line == 7, f)

-- jest / vitest: ✕ marks the test, the stack frame the location.
local jest_out = lines([[
 FAIL  src/calc.test.ts
  calc
    ✓ adds (2 ms)
    ✕ multiplies (5 ms)

  ● calc › multiplies

    expect(received).toBe(expected)

    Expected: 9
    Received: 10

      at Object.<anonymous> (src/calc.test.ts:12:21)

Tests:       1 failed, 1 passed, 2 total]])
f = testrun.parse_failures("js", jest_out)
check("jest: failure with location",
    #f == 1 and f[1].test == "calc › multiplies" and f[1].file == "src/calc.test.ts" and f[1].line == 12, f)
p, fl = testrun.parse_counts(jest_out)
check("jest: counts", p == 1 and fl == 1, { p, fl })

-- cargo test: the FAILED line names the test, the panic names the line.
local cargo_out = lines([[
running 2 tests
test tests::add ... ok
test tests::mul ... FAILED

failures:

---- tests::mul stdout ----
thread 'tests::mul' panicked at src/lib.rs:14:9:
assertion `left == right` failed
  left: 10
 right: 9

failures:
    tests::mul

test result: FAILED. 1 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out]])
f = testrun.parse_failures("cargo", cargo_out)
check("cargo: failure with location",
    #f == 1 and f[1].test == "tests::mul" and f[1].file == "src/lib.rs" and f[1].line == 14, f)
p, fl = testrun.parse_counts(cargo_out)
check("cargo: counts", p == 1 and fl == 1, { p, fl })

-- go test: a build failure is reported as such, not as zero failures.
local go_out = lines([[
# scratch [scratch.test]
./calc_test.go:7:2: undefined: Nope
FAIL	scratch [build failed]
FAIL]])
local gf, broken = testrun.parse_failures("go", go_out)
check("go: build failure named", #gf == 0 and broken and broken[1] == "scratch", { gf, broken })

-- make test with a go runner inside: the output is sniffed.
local sniffed = testrun.parse_failures("make", lines([[
go test ./...
--- FAIL: TestMul (0.00s)
    calc_test.go:14: Mul(3,3) = 10, want 9
FAIL
FAIL	scratch	0.001s]]))
check("make: runner sniffed from the output",
    #sniffed == 1 and sniffed[1].test == "TestMul" and sniffed[1].line == 14, sniffed)

-- Runner guess: a Makefile test target beats the language default, and
-- path/filter go to the language runner.
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.writefile({ "module x", "", "go 1.22" }, root .. "/go.mod")
vim.fn.writefile({ "test:", "\tgo test ./..." }, root .. "/Makefile")
local g = testrun.guess_test_command(root)
check("guess: Makefile test target first", g[1] and g[1].cmd == "make test" and g[2] and g[2].runner == "go", g)
g = testrun.guess_test_command(root, nil, "TestX")
check("guess: filter skips make and reaches go -run",
    g[1] and g[1].cmd == "go test ./... -run 'TestX'", g)
vim.fn.mkdir(root .. "/pkg", "p")
g = testrun.guess_test_command(root, root .. "/pkg")
check("guess: directory path narrows go", g[1] and g[1].cmd == "go test ./pkg/...", g)
-- "." is the root, which is no narrowing: it used to come out as ././...
g = testrun.guess_test_command(root, ".")
check("guess: a path of . is the root, not a subdirectory",
    g[1] and g[1].cmd == "make test" and g[2] and g[2].cmd == "go test ./...", g)
vim.fn.delete(root, "rf")

-- The generic parser reads prose, so it must not turn a warning printed by
-- a passing run into failing tests. unittest through `python -m unittest`
-- has no parser of its own, and the standard library's ResourceWarning
-- lines were reported as three failures next to the runner's own "OK".
local unittest_out = lines([[
...
/usr/lib/python3.14/tempfile.py:484: ResourceWarning: Implicitly cleaning up <HTTPError 404: 'Not Found'>
  _warnings.warn(warn_message, ResourceWarning)
----------------------------------------------------------------------
Ran 3 tests in 0.066s

OK]])
local generic = testrun.parse_failures(nil, unittest_out, "/tmp/project", 0)
check("generic: a passing run reports no failures", #generic == 0, generic)
local generic_failed = testrun.parse_failures(nil, unittest_out, "/tmp/project", 1)
check("generic: a warning from the standard library is not a failing test",
    #generic_failed == 0, generic_failed)
local real_failure = testrun.parse_failures(nil, lines([[
FAIL: test_add (tests.test_math.MathTest)
tests/test_math.py:12: AssertionError: add(1, 2) == 4
Ran 3 tests in 0.010s]]), "/tmp/project", 1)
check("generic: a real failure in the project is still reported",
    #real_failure >= 1, real_failure)

-- testify prints the location on one line and the detail under it.
local go_testify = testrun.parse_failures("go", lines([[
--- FAIL: TestLiteralColonWithRun (0.00s)
    gin_test.go:1077:
        	Error Trace:	/repo/gin_test.go:1077
        	Error:      	Not equal: expected: 418, actual: 200
FAIL]]), "/repo", 1)
check("go: a failure with the detail on the next line carries a message",
    go_testify[1] and go_testify[1].line == 1077
    and (go_testify[1].message or ""):find("Error Trace") ~= nil, go_testify)

-- python -m unittest had no parser: a failing run answered "no failures
-- parsed from the output" and the baseline stored every output line.
local unittest_out = lines([[
test_alpha (probe.test_plain.PlainTest.test_alpha) ... ok
test_beta (probe.test_plain.PlainTest.test_beta) ... FAIL

======================================================================
FAIL: test_beta (probe.test_plain.PlainTest.test_beta)
----------------------------------------------------------------------
Traceback (most recent call last):
  File "/repo/probe/test_plain.py", line 12, in test_beta
    self.assertEqual(2, 3)
AssertionError: 2 != 3

----------------------------------------------------------------------
Ran 2 tests in 0.001s

FAILED (failures=1)]])
local ut = testrun.parse_failures("unittest", unittest_out, "/repo", 1)
check("unittest: the failing test is named with its file and line",
    #ut == 1 and ut[1].test == "test_beta" and ut[1].line == 12
    and ut[1].file == "/repo/probe/test_plain.py"
    and (ut[1].message or ""):find("2 != 3") ~= nil, ut)

local sniffed = testrun.parse_failures(nil, unittest_out, "/repo", 1)
check("unittest output is recognised without being told the runner",
    #sniffed == 1 and sniffed[1].test == "test_beta", sniffed)

-- `go test ./...` prints "[no test files]" for every package without tests,
-- which is almost every repository: a whole passing suite was reported as
-- "no tests ran".
check("go: packages without tests do not make a passing run look empty",
    testrun.ran_nothing(lines([==[
?   	github.com/x/cmd/tool	[no test files]
ok  	github.com/x/internal/compat	0.004s
ok  	github.com/x/internal/policy	0.002s]==])) == false, "matched")
check("go: a filter that matched nothing, with no test having run, is recognised",
    testrun.ran_nothing(lines([==[
testing: warning: no tests to run
?   	github.com/x/cmd/tool	[no test files]]==])) == true, "not matched")
check("unittest: NO TESTS RAN is recognised",
    testrun.ran_nothing(lines([[
----------------------------------------------------------------------
Ran 0 tests in 0.000s

NO TESTS RAN]])) == true, "not matched")

if failures > 0 then
    io.stdout:write(("unit_testrun: %d failed\n"):format(failures))
    vim.cmd("cquit 1")
end
io.stdout:write("unit_testrun: OK\n")
io.stdout:flush()
vim.cmd("quit")
