# agent99

Agentic code edits and code questions inside Neovim, in the spirit of
[ThePrimeagen/99](https://github.com/ThePrimeagen/99) — grown into a small
background coding agent that lives in your editor.

Select a region, type an instruction, keep working: the request runs in the
background against an LLM whose tools are backed by the LSP clients
**already running inside your Neovim** — definition, references, hover,
symbols, diagnostics, code actions, and the unsaved state of your buffers —
so the agent explores the codebase the way you do, with a warm index and no
extra language-server processes. Edits land in your buffers; answers pop up
when you are free. Every run becomes a record you can search, inspect,
continue, or undo.

![The agent panel: tool activity streams while the agent explores, and the
code window follows what it reads](doc/panel-chat-working.png)

## The core loop

```
select region ──> compose picker ──> request runs in background
   <leader>99       type prompt          you keep editing
                    stack more                 │
                    selections           ┌─────┴──────┐
                                         ▼            ▼
                                   edit: applied   question: answer pops up
                                   to your buffer  when you are in normal
                                   (or preview)    mode with nothing open
                                         │            │
                                         └─────┬──────┘
                                               ▼
                                     a RECORD in the history:
                                     searchable · inspectable ·
                                     continuable · undoable
```

- **Auto mode**: `<leader>99` does not ask whether you want an edit or an
  answer — the model decides from your instruction (no extra classification
  call; the reply's shape resolves it). `<leader>9e` / `<leader>9a`
  hardcode edit / ask when you want certainty.
- **Nothing blocks**: tool calls reach the editor over a non-blocking RPC
  (start/poll, microseconds per poll), the request runs as a background
  job, and a finished answer waits until you are in normal mode with no
  other record open before appearing.
- **Everything is a record**: instruction, attached contexts, target
  region, the agent's step-by-step work, the diff or the answer, cost.
  Records are the unit of history, continuation, and undo.

## Install

lazy.nvim:

```lua
{ "iryzhkov/agent99", build = "make build", opts = {} }
```

With the debugger tools (optional; see "Debugging" below):

```lua
{
  "iryzhkov/agent99",
  build = "make build",
  dependencies = { "mfussenegger/nvim-dap" },
  opts = { debug = { enabled = true } },
}
```

or from a local clone: `{ dir = "~/src/agent99", opts = {} }` (run
`make build` there once).

Requirements: Neovim ≥ 0.11, Go (build time only — `make build` produces
`bin/agent99-bridge`, a static binary with no dependencies outside the Go
standard library), an API key, and working LSP in the buffers you edit.

## Providers

`provider` is a preset name, a preset with overrides, or a full table:

```lua
provider = "deepseek"                     -- built-in preset (the default)
provider = { preset = "ollama", base_url = "http://my-gpu-box:11434/v1",
             model = "qwen2.5-coder:14b", temperature = 0.2 }
provider = { base_url = "https://my.gateway/v1", model = "my-model",
             api_key_env = "MY_KEY" }    -- no preset at all
```

Built-in presets: `deepseek`, `openai`, `openrouter`, `ollama` (local, no
key), `claude` (spawns `claude -p` with the LSP tools over MCP — on a
Claude subscription this costs nothing per token; usage still lands on the
record via its JSON output; no chat/follow-ups). Define your own under
`providers = { mylab = {...} }` and refer to them by name.

`:Agent99Provider <name>` switches presets at runtime (tab-completes; no
argument shows the active provider). A practical split: a cheap default
for chat, `:Agent99Provider claude` for hard edits. `chat_provider` names
a preset the chat panel falls back to automatically when the main provider
cannot chat.

Provider fields (all overridable per preset): `kind` (`"openai"` for any
OpenAI-compatible chat-completions API, `"claude"`), `base_url`, `model`,
`api_key` / `api_key_env` / `keyring_service` (resolution order: literal
key — for local servers, not real secrets — then environment, then the
system keyring via `secret-tool`; `:Agent99SetKey` stores a key in the
keyring with concealed input, no dotfile plain text), `temperature`,
`max_tokens`, `max_rounds`, `full_tools`, and for claude: `claude_cmd`,
`allowed_tools`.

## Composing a request

Visually select lines, press `<leader>99`: a telescope-style compose picker
opens — selection list top-left (first entry is the target), instruction
prompt below it, syntax-highlighted preview of the highlighted selection on
the right.

![The compose picker: target and stacked context selections, the
instruction draft, and a live preview](doc/compose.png)

- Type the instruction, `<CR>` (insert: `<C-s>`) sends.
- **Sticky drafts**: `q`/`<Esc>` closes without losing anything; invoking
  `<leader>99` (or `9e`/`9a`) again from another selection — any file —
  stacks it as additional context instead of starting over, so one request
  can carry several regions. `<leader>99` in normal mode reopens the draft.
- Navigate with `<C-j>`/`<C-k>` from the prompt or `<Tab>` into the list
  and `j`/`k`; `x` removes a context, `gx` discards draft and stack.
- `gm` cycles the mode: auto → edit → ask.
- `gr` opens the requests picker and attaches a past run's conversation to
  the current draft — continue a previous discussion against a new target.

While an edit runs, the target region is highlighted with an
`agent99 working…` marker. The selection is the primary edit target
(changed via the reply's `<replacement>` contract), but not the boundary:
changes that belong elsewhere go through symbol-addressed edit tools, land
in editor buffers immediately, and are all tracked. With `preview = true`
(default) the replacement opens in a split — `<CR>` applies, `q` discards.

## Requests and records

`<leader>9h` (`:Agent99History`) searches requests — a telescope picker
scoped to the current workspace (project roots containing or contained by
the cwd; `:Agent99History all` lifts the filter). The running request leads
the list live; past ones follow, newest first, with undotree-style ages.
Fuzzy search covers time, status, mode, target file, instruction, and the
`@now`/`@past` session tokens; the preview shows what the agent was given
and what came back. Chat conversations collapse to one entry each.

![The requests picker: fuzzy search over workspace history with a
what-was-asked / what-came-back preview](doc/history.png)

`<CR>` opens the **record view** — a multi-pane float:

```
+----------+---------------------+------------------+
| sections | answer / change /   |  prompt          |
| info     | ctx (selected, 120  +------------------+
| work     | unwrapped columns)  |  target: file:…  |
|> answer  |                     |  (the selected   |
| ctx: …   |                     |   region's code) |
+----------+---------------------+------------------+
```

![The record view: sections, the rendered answer, and the prompt and
target panes](doc/record.png)

- Opens on the payload (answer or change); `j`/`k` walk the sections,
  `<Tab>` cycles panes. Edits render as Before/After blocks in the file's
  own language (a pure insertion is a single Added block); answers as
  markdown. `work` is the agent's run, step by step: what it said between
  tool calls and every call with its result size. The footer carries the
  run's stats (`10m ago · 12.3k/2.9k tokens · deepseek-chat · 6 rounds`).
- `<CR>` on a section with a location (target, ctx, change, an edit) — or
  `gt` for the target from anywhere — leaves the view and visually selects
  that region in your last active window.
- `gc` **continues** the run: compose opens with the target restaged and
  the conversation attached; type the new prompt (flip mode with `gm`).
- `gu` **undoes** the run: the replacement and every symbol edit are
  reverted — each block only if the buffer still contains exactly what the
  run wrote (found by unique search if lines shifted); anything since
  modified is skipped and reported.
- `<C-h>`/`<C-l>` step to the chronologically older/newer record in the
  workspace without leaving the view.
- `<leader>9r` (`:Agent99Record`) reopens the last shown record.

A finished question opens this same view — but never interrupts: if you
are mid-edit or already reading a record, it queues with a notification
and appears at the next quiet moment. Opening a **chat** record instead
restores that conversation into the panel, ready to continue.

## The chat panel (`<leader>9c`)

A vertical split on the right — scrolling conversation above a prompt —
while your code window stays on the left and **follows the agent**:
deliberate reads move it to the file being read, edits jump it there with
a brief highlight.

![A finished answer in the panel, with file:line citations and the cost
line](doc/panel-chat.png)

- Everything streams live: tool activity, then the answer token by token,
  then a cost line. The pane renders as markdown.
- `<leader>9c` from a visual selection stages it as context for the next
  message — mid-conversation, from any file.
- `/help` lists panel commands: `/clear` (starts a new conversation — the
  old one stays in the history as a single restorable entry), `/revert`,
  `/cancel`, `/stats` (session usage; `/stats all` lifetime), `/history`,
  `/hide`.
- The conversation persists for the whole Neovim session; chat needs an
  openai-kind provider (see `chat_provider`).

## Safety and telemetry

- If the selected region changed while the agent worked, the apply is
  refused (hash guard) and the proposal is kept in the history.
- After an apply, new ERROR diagnostics trigger one automatic fix round
  with the agent's full conversation (never a fix-of-a-fix).
- An applied edit reverted by the user within 30s is marked on its record —
  the strongest "bad edit" signal — and undo via `gu` is tracked the same.
- Every request persists as JSON under `stdpath("state")/agent99/history/`
  (pruned to `history.keep`) with outcome, per-tool call counts, token
  totals, duration, and the full transcript alongside. `:Agent99Stats`
  aggregates outcome rates, cost, and tool usage; the records are plain
  JSON, so deeper analysis is a `jq` away. `<leader>9l` opens the log with
  a per-request trace.

## Options

```lua
require("agent99").setup({
    -- everything below is the default
    provider = "deepseek",
    providers = {},              -- your own presets, by name
    chat_provider = nil,         -- panel fallback when the main provider cannot chat
    preview = true,              -- proposal split with <CR> apply / q discard
    auto_fix = true,             -- new ERRORs after an apply trigger one fix round
    auto_fix_delay_ms = 2000,
    post_edit = {                -- what symbol edit tools do and report after applying
        format = "range",        -- format the edited region via the server ("file" for whole file, false off)
        organize_imports = true, -- run the server's source.organizeImports after each edit
        wait_ms = 4000,          -- max wait for servers to re-publish (returns when settled)
        check = nil,             -- check_project command, e.g. "go vet ./..." (nil: guessed)
        commands = {},           -- linters per filetype: { python = "ruff check {file}", go = "go vet {dir}" }
        nvim_lint = true,        -- also run nvim-lint's linters for the filetype, if installed
        lint_timeout_ms = 30000,
    },
    context_full_file_max = 200, -- embed whole file in the prompt up to this size
    context_lines = 50,          -- else this many lines around the selection
    timeout_ms = 5 * 60 * 1000,
    auto_mode = true,            -- <leader>99 lets the model infer edit vs question
    history = { keep = 100 },    -- request records kept on disk
    debug = {
        enabled = false,         -- advertise the debugger tools (needs nvim-dap on the runtimepath)
        idle_ms = 10 * 60 * 1000, -- end an agent-started session untouched for this long
    },
    ui = {
        width = 0.4,             -- chat panel width (fraction of columns)
        input_height = 5,        -- chat prompt height
        record = {               -- record view layout
            content_width = 120, list_width = 26, border = "rounded",
        },
        compose = {              -- compose picker layout
            width = 170, height = 24, preview_ratio = 0.7,
            prompt_height = 5, border = "rounded",
        },
    },
    keymaps = {                  -- false disables all; set a key to false to drop one
        auto = "<leader>99",            -- x: compose, model infers edit/ask
        compose = "<leader>99",         -- n: reopen the compose draft
        edit = "<leader>9e",            -- x: compose, hardcoded edit
        ask = "<leader>9a",             -- x: compose, hardcoded ask
        chat = "<leader>9c",            -- n: toggle the chat panel
        chat_selection = "<leader>9c",  -- x: panel with selection as context
        followup = "<leader>9f",        -- n: follow up on last edit/answer
        cancel = "<leader>9x",          -- n: cancel request / discard preview
        history = "<leader>9h",         -- n: search requests
        record = "<leader>9r",          -- n: re-open the last record view
        logs = "<leader>9l",            -- n: view logs
    },
    bridge_bin = nil,            -- default: <plugin>/bin/agent99-bridge
})
```

telescope.nvim is an optional integration (the requests picker uses it
when installed, with a plain-split fallback), never a dependency.

## How it works

```
Neovim (your editor, LSP clients attached)
  │  compose / chat / followup
  │  spawns bin/agent99-bridge (one static Go binary, stdlib only)…
  ├─ agent99-bridge agent             (openai-kind providers)
  │    OpenAI-compatible function-calling loop with loop hygiene:
  │    repeated calls nudged, byte-identical results deduplicated,
  │    stalled rounds force an answer.
  │    LSP tools call back into Neovim over a NON-BLOCKING protocol:
  │    `--remote-expr Agent99RpcStart(...)` starts the tool in a coroutine
  │    and returns immediately; the bridge polls Agent99RpcPoll(...) for
  │    the result, so the editor UI never freezes during a tool call.
  │
  └─ or `claude -p` + agent99-bridge mcp      (claude provider)
       The same LSP tools exposed as an MCP stdio server.

Standalone: any MCP client + agent99-bridge mcp
  open_workspace(root) starts a headless Neovim there; the tools
  then run against its language servers (see "Using the tools from
  other agents").
```

## The agent MCP server

The same tool set is an MCP stdio server: `bin/agent99-bridge mcp`. Claude
Code, or any MCP client, can use it outside Neovim:

```
claude mcp add --scope user agent99 -- ~/.local/share/nvim/lazy/agent99/bin/agent99-bridge mcp
```

The point of it is that an agent working through these tools sees the code
the way an editor does rather than the way `cat` does. It navigates by
symbol instead of by line number, it is told what its edit broke the moment
it makes it, and its refactors go through the language server, so the
imports and references that have to move with a change actually move.

### What you get over plain file tools

- **Structure instead of text.** `workspace_map` gives every file in the
  project with its declarations — classes with their methods one level in —
  in one call. `find_symbol` fetches one function out of a 1600-line module
  by name path (`Flask/full_dispatch_request`), with its lines numbered
  relative to the symbol so the next edit can address them directly.
- **Annotated search.** Every `grep` hit is tagged with the symbol that
  encloses it, its kind, nesting depth, existing diagnostics and whether it
  is in a test file, so most hits need no follow-up read.
- **Edits that keep the file valid.** After every symbol edit the region is
  formatted through the server and imports are organized, so writing a call
  into a package the file does not import yet costs no extra round trip.
- **Immediate feedback.** Each edit returns the diagnostics it introduced,
  separated from the ones that were already there and the ones it fixed.
  `check_project` does the same for the project's own check command against
  a baseline.
- **Refactors, not text substitution.** `rename_symbol` and `move_file` go
  through the language server, which rewrites every reference and import
  path across the project.

### Workspaces

Without `$AGENT99_NVIM` the server runs in **standalone mode**: it serves
`open_workspace(root)`, which starts a headless Neovim in that project with
your normal configuration (so the same language servers attach), and
routes every later tool call to it. Its reply lists the languages found
in the root with the parser and language server each one got, and warns
about languages the instance cannot serve (`workspace_map` and `skim` say
the same when they meet such files). LSP tools return an error until a
workspace is open; `close_workspace` stops the instance, and it is also
stopped when the server exits. Standalone mode additionally serves the
file tools (`read_file`, annotated `grep`, `list_files`), with relative paths resolved against the
workspace, and symbol edits are saved to disk right after they are
applied since nobody is at the keyboard to `:w`. One workspace at a time;
opening a different root replaces the instance, and its state (loaded
buffers, the `check_project` baseline) goes with it.

If the server inherits `$NVIM` (Claude Code launched from a `:terminal`
inside Neovim), that live instance is used instead and `open_workspace` is
unnecessary — and the tools then see your unsaved buffers.
`AGENT99_HEADLESS_INIT=<init.lua>` makes the headless instance start with
`--clean -u <init.lua>` instead of your configuration (the tests use it;
then language servers must be on `PATH`, since mason.nvim is not there to
add them).

### Sharing the tree with other tools

The buffers behind these tools are long-lived, so a file can change
underneath one: the agent runs `sed`, a `git checkout` lands, you save in
your own editor. Every buffer carries the disk fingerprint its contents
were last known to agree with, and is resynced before it is read or
edited — an external change is picked up, not written over. When the file
changed *and* the session has unsaved edits of its own, the tool refuses
and says so rather than choosing which change to lose. Writes go through
`write!` after that check, so the "file has changed since reading it,
write anyway?" prompt — unanswerable in a headless instance — can never be
reached.

### File lifecycle

`create_file`, `move_file` and `delete_file` let a refactor that adds,
splits or renames a file stay inside the editor. Each one tells the
language servers what happened through the `workspace/*FileOperations`
requests, and each is undoable through `undo_edit` like any other edit
(`delete_file` restores the contents).

`move_file` is the one that earns its place: the server is asked what else
must change *before* the file moves, so the imports naming the old path are
rewritten across the project. Moving `packages/zod/src/v4/core/regexes.ts`
into a `patterns/` subdirectory rewrote the import in five other files;
a shell `mv` would have left five broken imports for the agent to find.

`create_file` makes missing parent directories, formats the new file and
organizes its imports, and refuses to overwrite an existing file.

### Globs

`glob` means the same thing in every tool that takes one: a path pattern
matched against the path from the workspace root, where `**` spans
directories. So `src/**/*.go` works, `**/*.ts` matches everywhere, and a
bare `schemas.ts` is treated as "wherever it lives". A glob that matches
nothing says so, and says why, instead of returning an empty result that
reads like an answer.

### When a language server knows less than it looks

Some servers only index the files they have been shown — tsserver builds
its program from open files, so `workspace_symbols` in a large repository
can answer about a fraction of it. Rather than report that as "no match",
which is indistinguishable from the symbol not existing, the tool waits
for indexing, opens the project's most central source file to give the
server its real configuration, and then falls back to reading the
project's own files. Results found that way are labelled.

### Extras

`AGENT99_LINT_<FILETYPE>` in the server's environment (`claude mcp add -e
AGENT99_LINT_GO="go vet {dir}" ...`) sets a post-edit linter without touching
the Neovim config; `{file}`, `{dir}` and `{root}` are expanded.

When `open_workspace` reports a language with no parser and no server, the
standalone server also offers `install_language(language)`: it installs the
tree-sitter parser through nvim-treesitter and a language server through
Mason (a sensible default per filetype, `server=` to pick another, `none`
for parser only), enables the server and checks that it attaches to a file
of that language in the workspace. Each step reports what it did or why it
could not (no nvim-treesitter or Mason in the config, a server whose
toolchain is missing such as `cargo` for rust_analyzer). Installed pieces
land in Neovim's data directory and persist; add them to the editor
config's ensure-installed lists to keep them on a fresh machine.

### Debugging

The tools above read and edit a program; these run it and look at it while
it is stopped, through a Debug Adapter Protocol session that
[nvim-dap](https://github.com/mfussenegger/nvim-dap) drives inside the same
Neovim. A breakpoint can be placed by symbol name path, every stop reply
names the enclosing symbol the way grep hits do, and the paused frame is one
`find_symbol` away in the same tool set. In embedded mode the session is
the user's nvim-dap session: the agent sees the user's breakpoints, the
user sees the agent's, and a stop shows in both.

**Off by default.** Thirteen schemas cost prompt tokens on every round for a
model that is not debugging, so the tools are advertised only when asked
for: `debug = { enabled = true }` in `setup()` for the plugin (it passes
`AGENT99_DEBUG=1` to the bridges it spawns), and `AGENT99_DEBUG=1` in the
standalone server's environment (`claude mcp add -e AGENT99_DEBUG=1 ...`).
When off, `open_workspace` still reports a `debugger` field per language,
so a client learns the option exists. nvim-dap must be on the runtimepath;
without it every debug tool says so and nothing else changes.

**Adapters.** The user's `dap.configurations` win when they exist
(`debug_launch(config="name")`, or the first launch entry for the file's
filetype). Function-valued fields are evaluated with every prompt replaced
by an error naming the field, because a `vim.ui.select` in a headless
instance would hang forever. Without a user configuration, built-ins cover
Go (Delve, spawned by agent99 so its output is captured), Python (debugpy
from the project's venv, the system interpreter or Mason's package, with the
program run under the project's venv), C/C++/Rust (codelldb, then lldb-dap,
then gdb 14+'s own DAP mode), JavaScript/TypeScript (vscode-js-debug from
Mason's js-debug-adapter; `.ts` files run through Node's own type stripping,
so breakpoints in TypeScript need no build; the program lives in a child
session js-debug opens, which the tools follow) and Java (Microsoft's
java-debug, a jdtls plugin: agent99 adds Mason's java-debug-adapter bundle
to the jdtls config when the user set none, asks the running jdtls for a
debug port, and resolves the main class and classpath through it; the
project must be one jdtls imports, that is Maven, Gradle or Eclipse
`.project` files, a bare folder of sources gets a wrong classpath).
`install_debugger(language)` fetches delve, debugpy, codelldb,
js-debug-adapter and java-debug-adapter through Mason.

**One stop, one turn.** Launch, attach, continue, step and wait all reply
with the same stop context: reason, frame (`file`, `line`, `symbol`,
`at` = line within the symbol), a five-line source window with the current
line marked, up to twelve locals as `name: type = value` clipped at 120
characters, the top six frames with runs outside the workspace (or in
site-packages, node_modules, vendor, a venv) collapsed into `<external ×N>`,
the breakpoint hit, program output since the last reply, expressions from
the `track` list given at launch, and `stale_source` naming files edited
since the launch. Exit replies carry the exit code and the output tail;
"running" is a normal answer, with `debug_wait` to keep waiting and
`pause_after` to interrupt. Variables can be `summary` (default), `names`
(no values, for large or sensitive locals) or `none`, chosen at launch.

**Process ownership.** A launched program is terminated by `debug_stop`,
by `close_workspace`, when the idle watchdog fires (`debug.idle_ms`,
default 10 min, `AGENT99_DEBUG_IDLE_MS` for the server), when Neovim exits,
and when the bridge dies (the adapter's connection drops and Delve, debugpy
and gdb all kill what they launched). An attached process is left running
by `debug_stop` unless `force=true`; on Linux with `kernel.yama.ptrace_scope=1`
attaching by pid fails and the error says so — start the target under
`dlv exec --headless --accept-multiclient --listen 127.0.0.1:PORT` or
`python -m debugpy --listen PORT --wait-for-client` and use `host`/`port`,
which always works.

Two heuristics worth more than any tool option: stepping more than three
times in a row means a breakpoint would serve better (`debug_continue`
takes `to=` for run-to-line), and break at the call site in your own code
rather than inside library code, with a `condition` inside loops.

Not built, on purpose: stdin to the debuggee (a program that reads it shows
as running forever; redirect input through a wrapper), more than one
session at a time, exception-breakpoint configuration, disassembly and
memory, a REPL passthrough (`debug_evaluate` with `context="repl"` covers
the legitimate use), and streaming output outside replies.

## Tools exposed to the agent

| Tool | Backed by |
|---|---|
| `install_language` | standalone MCP only: tree-sitter parser via nvim-treesitter plus a language server via Mason for one filetype, enabled and attach-checked; the fix for languages open_workspace calls blind |
| `debug_launch`, `debug_attach` | start a program under its debug adapter (Go, Python, C/C++/Rust built-ins, or a user nvim-dap configuration by name), or attach by pid or to a debug server by host/port, and wait for the first stop; `debug_launch()` with no arguments relaunches the previous configuration with breakpoints and `track` kept. `AGENT99_DEBUG=1` / `debug.enabled` advertises these |
| `debug_breakpoint`, `debug_breakpoints` | set/remove a breakpoint at a line or at a symbol name path plus offset (with `condition`, `hit_condition`, `log_message`), before or during a session; the reply says where the adapter actually put it. List or clear the agent's own breakpoints — the user's are never touched |
| `debug_continue`, `debug_step`, `debug_wait` | resume (or run to a line), step over/into/out `count` times, wait for a running program (`wait_ms=0` = just report, `pause_after` interrupts); every one replies with the stop context: frame with symbol, source window, locals, stack, output since the last reply, tracked expressions, stale-source warning |
| `debug_stack`, `debug_variables`, `debug_evaluate`, `debug_output` | the rest on demand: deeper stack with external frames collapsed, variables of a frame one level deep or one path expanded, an expression in a frame, and the captured output (up to 200 lines, surviving the exit) |
| `debug_stop` | terminate a launched program or disconnect from an attached one (left running unless `force`), remove the agent's breakpoints, kill the adapter if it lingers |
| `install_debugger` | standalone MCP only: delve, debugpy, codelldb, js-debug-adapter or java-debug-adapter through Mason, for a language whose `debugger` field says none |
| `workspace_map` | the whole workspace's shape in one call: every project file with its line count and its declarations, descending one level into classes so nested languages list their methods (string parsers on disk content — no buffers created, no servers attached); the outline budget is shared across files (`+N more` marks a cut), test files are left out unless `include_tests`; the intended first move in an unfamiliar repo, ahead of skim/grep. Markdown files list their headings |
| `skim` | structure of up to 20 files in one call: every function/class/method declaration line with line numbers, nested (treesitter, LSP-symbol fallback; C/C++ take the server's symbols first because macros confuse the grammar) — measures ~6-25% of the tokens of reading the same files. Markdown headings index like declarations, so a README's sections are name paths (`Install/Requirements`) for `find_symbol`, the section edits and grep's hit tags |
| `find_symbol` | look up symbols by `/`-joined name path across files/globs, optionally returning the full body — fetch exactly one function instead of a whole file. Constants and module-level variables are included by folding in the server's document symbols, which treesitter's declaration nodes leave out. A name path that matches nothing answers with `count: 0` and `suggestions` (the symbols sharing its last segment), never with fuzzy matches that read like the symbol being found somewhere else |
| `ts_query` | structural multi-file search: a treesitter s-expression query with `@captures` and `#eq?`/`#match?` predicates — for questions grep can't ask |
| `definition`, `type_definition`, `implementation` | `textDocument/*` via live client |
| `hover` | `textDocument/hover` (signatures + docs) |
| `expand_symbol` | definition + full source of the defining symbol + hover, in one round-trip |
| `references` | `textDocument/references`, grouped by file (paths relative to the root), each hit annotated with its enclosing symbol path |
| `document_symbols`, `workspace_symbols` | file outline / project-wide symbol search. `workspace_symbols` falls back to reading the project's files when the server's index does not cover them, rather than reporting a gap in the index as "no match" |
| `diagnostics` | `vim.diagnostic.get` (what the editor shows); fixable ones list their `quick_fixes`, steering the agent to `apply_code_action` instead of hand-writing fixes |
| `incoming_calls`, `outgoing_calls` | call hierarchy (server support varies) |
| `code_actions`, `apply_code_action` | list the editor's quick fixes/refactorings, apply one by token+index; the edit is performed by Neovim itself (safe, possibly multi-file) |
| `rename_symbol` | `textDocument/rename` project-wide; `dry_run` lists affected files and edit counts first; applied renames enter the undo ledger per file |
| `check_project` | one project-wide check from the root (`post_edit.check`, `AGENT99_CHECK`, or guessed from go.mod / tsconfig.json / Cargo.toml / pyproject.toml); the first call in a root records a baseline, later calls report only new and resolved lines |
| `undo_edit` | take back the newest edit(s) of the run (`count`, or `all`), restoring the recorded source, or reversing a create/move/delete; refuses when the region changed since, and does not cover code actions |
| `replace_symbol_body`, `replace_symbol_lines`, `insert_after_symbol`, `insert_before_symbol` | symbol-addressed edits, applied to editor buffers immediately and tracked (undoable per run). The two replacements take `dry_run` and return a unified diff without applying, the way `rename_symbol` always has. `replace_symbol_lines` takes `expect=`, the text those lines currently hold, so a line number that went stale when something above the symbol moved is refused instead of overwriting working code; the refusal finds where that text now sits and offers the relocated edit as a code action, so `apply_code_action(token, 1)` finishes it without a re-read (index 2 forces the requested lines). Several places in one file go in `chunks`, each naming its own symbol, applied together bottom-up, all or none, with each region formatted on its own so the code between them is untouched. It also echoes back what it replaced. When a formatter changes lines beyond the edited region (lua_ls drops a blank line after a function that shrank), the ledger folds them in, so `undo_edit` restores the file exactly. After every edit the region is formatted through the server and imports organized (a new call into an unimported package costs no extra round), with the formatting confined to the edited lines even where the server only offers whole-file formatting, so a change to a file that was never formatter-clean stays a small diff; then the tool waits for the servers to re-publish and returns only the errors/warnings the edit introduced, plus new errors in other open files and optionally a linter's output (see `post_edit`). The pre-existing diagnostics are listed once and reported as "no change" until they differ; `full_diagnostics` lists them again |
| `move_symbols` | move whole symbols from one file into another, each with its doc comment, reorganizing the imports of both afterwards — the way to split an oversized file, which no other symbol tool can express because the unit is a run of independent declarations rather than one symbol. Creates the destination if missing (inferring a `package X` header where the language has one), and is undoable |
| `create_file`, `move_file`, `delete_file` | file lifecycle through the language servers (`workspace/*FileOperations`), so a refactor that adds, splits or renames a file does not have to leave the editor. `move_file` has the server rewrite the imports naming the old path before the move; `create_file` makes parent directories, formats and organizes imports, and refuses to overwrite; `delete_file` reports what broke elsewhere. All three are undoable through `undo_edit` |
| `buffer_lines` | editor's live buffer content, **including unsaved changes** |
| `grep` filters | `kind=` keeps only definitions, calls, comments, strings, or `code` (anything that is not a comment or a string) — the fix for an identifier that also appears in the prose above every use of it; `tests=exclude`/`only` splits production code from tests on the path. Filtering by kind implies no context lines, and says how many hits were never classified rather than quietly dropping them |
| `read_file`, `grep`, `list_files` | plain file access rooted at the project (openai-kind providers; claude brings its own Read/Grep/Glob). A plain read of a large file returns its skim instead of thousands of lines. Grep output is deterministic and every hit is annotated: `file:line [Symbol kind @pos/len dN !SEV ~age · signature · doc-comment]` — what the hit *is*, where it sits, its nesting depth, existing diagnostics, `test:` for test files, blame age on request — so most hits need no follow-up read |

Positions are addressed as `(file, line, symbol-text-on-that-line)` instead
of raw columns — far more reliable for an LLM, with UTF-16 conversion
handled on the Lua side.

**Slim default roster**: `document_symbols` and `expand_symbol` are not
advertised by default, because `skim` and `find_symbol include_body` are the
same information and every advertised schema costs prompt tokens per round.
They remain callable, and `full_tools = true` (or `AGENT99_FULL_TOOLS=1` for
the MCP server) re-advertises them.

The list used to be longer, trimmed on measured usage — which is circular for
a tool the model is never shown. A session tracing a bug asked for a call
hierarchy and a find-implementations tool as missing features while
`incoming_calls`, `outgoing_calls` and `implementation` sat in that list,
implemented and invisible. They are advertised now.

## Tests

```
make build   # compile bin/agent99-bridge (Go, stdlib only)
make smoke   # bridge + all LSP tools against a headless nvim + lua_ls; free
make e2e     # one real agent edit through DeepSeek; needs DEEPSEEK_API_KEY
```

`tests/smoke.sh` starts a throwaway headless Neovim with a minimal config
on the bundled `tests/testproj`, then asserts on real lua_ls results
through the MCP bridge. lua-language-server must be on PATH or in mason's
bin directory.

The debugger tools are exercised by `tests/drive_debug.py` against a real
Delve session on `tests/debugproj`: breakpoints by name path, launch, step,
variables, evaluate, run to exit, stale-source detection, relaunch, attach
to a headless `dlv` server, the ptrace hint, the idle/timeout paths, and
that neither `close_workspace` nor a SIGKILL of the bridge leaves a debuggee
behind. `smoke.sh` installs the pinned Delve (`DLV_VERSION`) into
`~/.cache/agent99-tests/bin` and clones nvim-dap at a pinned commit under
`tests/.deps` (or uses `$AGENT99_TEST_NVIM_DAP`); if either fails it prints
a skip line, which `AGENT99_TEST_REQUIRE_DEBUG=1` turns into a failure.

## Known limitations

- One request at a time.
- The reply replaces the selection; agent-driven multi-file editing goes
  through the symbol tools and `apply_code_action`.
- One workspace at a time; opening another root replaces the instance and
  its state (loaded buffers, the `check_project` baseline).
- Auto-fix compares diagnostics by severity+message, so a pre-existing
  error the edit duplicates on another line still counts as new.
- A language server analyzes one build configuration, so a file excluded by a
  build tag gets no diagnostics at all. Edits there report that they were not
  checked rather than reporting success; verify them by building or testing
  with the tags that include the file.
- Debugging: one session at a time (the tools say so when nvim-dap has
  more), no stdin to the debuggee, attach-by-pid needs `ptrace_scope=0` on
  Linux, Java needs a project jdtls can import (not a bare folder), and
  java-debug reports exit code 0 whatever the program returned.

## Ideas / next steps

- Hunk-based diff preview (show only what changed, via vim.diff).
- Charwise/blockwise selections (currently widened to whole lines).
- FIM-based ghost-text completion as a separate fast path.
- A CLI entry point driving a running (or headless) editor — most of a
  standalone coding agent already exists here (the MCP server's
  `open_workspace` is the headless half).
