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
  (pruned to `history.keep`) with outcome, per-tool call counts and time
  spent in each tool (and per call, keyed by call id, so the record view
  shows every call's duration next to its reply size), token totals,
  duration, and the full transcript alongside. `:Agent99Stats` aggregates
  outcome rates, cost, and tool usage with the seconds and average
  milliseconds per tool; the records are plain
  JSON, so deeper analysis is a `jq` away. `<leader>9l` opens the log with
  a per-request trace.
- **Off by default**, the MCP server can spool one JSON line per tool call to
  `~/.local/share/toolfeedback/agent99/<host>-<date>.jsonl`: the tool, which
  argument *names* were present, whether it failed, a class of the error, how
  long it took, the commit the workspace was on, and which build of the bridge
  answered. It never records argument values or replies, because those carry
  the code being worked on, and error messages are folded into a class — paths,
  quoted text and numbers replaced by placeholders — before they are written.
  The point is to find out which tools agents actually struggle with instead of
  asking one afterwards, which produces a fluent but partly invented answer.

  Nothing is written until you ask for it, and nothing is ever transmitted
  anywhere: turn it on with `AGENT99_FRICTION=1`, or by creating the file
  `enabled` in the spool directory. `AGENT99_FRICTION=0` forces it off,
  `AGENT99_FRICTION_DIR` moves the spool.

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
        format = false,          -- format the edited region via the server: "range", "file", or false (default: off)
        organize_imports = true, -- run the server's source.organizeImports after each edit
        wait_ms = 4000,          -- ceiling on the wait for the servers' verdict after an edit
        settle_ms = 300,         -- starting quiet time after a publish or an acknowledged edit; learned per server from there
        wait = true,             -- false: edit tools return at once, the verdict rides on the next reply
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

- **Structure instead of text.** `open_workspace` answers with the
  workspace tree: directories with their file and line counts, languages
  and biggest files, so a wrong root is obvious and the right subdirectory
  is named before anything is read. `workspace_map` gives every file in a
  directory with its declarations — classes with their methods one level in —
  in one call. `find_symbol` fetches one function out of a 1600-line module
  by name path (`Flask/full_dispatch_request`), with its lines numbered
  relative to the symbol so the next edit can address them directly.
- **Annotated search.** Every `grep` hit is tagged with the symbol that
  encloses it, its kind, nesting depth, existing diagnostics and whether it
  is in a test file, so most hits need no follow-up read.
- **Edits that keep the file valid.** After every symbol edit imports are
  organized, so writing a call into a package the file does not import yet
  costs no extra round trip. Formatting through the server is opt-in
  (`post_edit.format`, `AGENT99_FORMAT`, or `format=` on the call), so by
  default the text lands byte for byte as the agent wrote it. When it is
  asked for, the pass is checked before it is kept: a formatter that
  rewrites the text inside a string literal, or that re-indents to a width
  the file does not use, has its pass taken back and the reply says so.
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
routes the calls naming a path in that tree to it. Its reply carries the
workspace tree (`workspace_tree`'s view of the root: directories with file
and line counts, languages and biggest files, so a wrong root is obvious
at once) and lists the languages found in the root with the parser and
language server each one got, warning about languages the instance cannot
serve (`workspace_map` and `skim` say the same when they meet such files).
`close_workspace` stops an instance, and every one of them is stopped when
the server exits.
Standalone mode additionally serves the
file tools (`read_file`, annotated `grep`, `list_files`), with relative paths resolved against the
workspace, and symbol edits are saved to disk right after they are
applied since nobody is at the keyboard to `:w`.

Calling `open_workspace` first is the explicit form, not a requirement. When
an LSP tool arrives and nothing is open, the server opens the project the
call is already talking about — the tree around a path in its arguments,
otherwise the one around its working directory, found by walking up to a
`.git`, `go.mod`, `package.json`, `Cargo.toml`, `pyproject.toml` or the
like. The friction spool is what asked for this: "no Neovim to talk to:
call open_workspace(root) first" was one of the commonest failures in real
sessions and every one of them recovered identically, by calling
`open_workspace` with the root the failed call had just named. A call with
nothing to infer from still returns that error, because guessing a root
wrongly is worse than asking for one.

A call that names no absolute path and no `workspace=` is refused while several are open, rather than routed by a guess: the sticky "where the last call went" pointers live in the server, and one server is shared by every agent talking to it, so the guess can be another agent's repository. An edit is refused outright when its path lies outside the workspace it was routed to (reading outside stays allowed — a dependency, a system header). Several projects can be open at once (ten by default,
`AGENT99_MAX_WORKSPACES` to change it — each workspace is a Neovim with its
own language servers, so the ceiling is the machine's memory). The refusal
at the limit names the open roots and says to close one of your own or wait:
when several agents share one server, the roots it lists may be theirs. A root that contains, or is contained by, an open
workspace is refused: two instances over one file tree would each hold
their own buffers for the same files, and an edit made in one would be lost
the moment the other wrote. Sibling projects and separate worktrees of the
same repository are fine.

The home directory and a filesystem root are refused as well. They are not
projects: everything that walks a workspace walks all of it — the file
scans behind `find_symbol` and `workspace_map`, and the language servers
doing their own indexing — and the friction spool measured what that costs.
Single edits in a workspace rooted at `$HOME` took 244s, 255s and 476s,
against a median of 1.4s for the same tool in a project root. Open the
repository or the config directory the work is actually in, or set
`AGENT99_ALLOW_WIDE_ROOT=1` to mean it.

Each call is routed to the workspace that owns the path it names, so an
absolute path is enough to address a project. A call whose paths are all
relative, or which names no path at all (`check_project`, `undo_edit`,
`workspace_symbols`, the debugger), goes to the *active* workspace — the
one the last call was routed to — unless it passes `workspace=<root>`,
which those tools take for exactly this reason. Two sticky exceptions keep
the common sequences right: `undo_edit` follows the workspace that was last
edited even if a read of another one came in between, and
`apply_code_action` follows the one that issued the token. A single call
cannot span two workspaces (`move_file` from one to another is refused),
and a path in no workspace at all — a dependency under `~/go/pkg/mod`, a
header in `/usr/include` — is read in the active one rather than rejected.

While more than one workspace is open, every reply starts with a
`workspace: <root>` line, so a misrouted call is visible instead of silent.
`close_workspace` stops one instance (by `root`, or the only one, or `all`)
along with its state: loaded buffers and the `check_project` baseline go
with it, though a check command remembered with `remember=true` is stored
per root under Neovim's state directory and survives.

A workspace also goes away on its own in two cases, and comes back by
itself in both. If its Neovim dies — a crash, the OOM killer — the next
call that names a path in that tree starts it again rather than answering
"no Neovim to talk to: call open_workspace first", which is an error the
agent has to notice and recover from in the middle of doing something
else. And a workspace nothing has touched for 30 minutes is closed, since
each one is a Neovim with a full set of language servers behind it: a
`lua-language-server` alone runs a few hundred megabytes, and a session
holding two workspaces was measured at 923 MB. `AGENT99_WORKSPACE_IDLE`
takes a duration (`45m`, `2h`); `0` or `off` keeps them up for the whole
session, the way they used to be. Because the next call reopens it, an
idle close costs a slow call rather than a failure — that is what makes
the timeout safe to have at all. Both events are noted on stderr, where
the MCP client logs them.

A Neovim killed outright cannot remove its own socket, so the server
sweeps the runtime directory at startup for sockets whose owning bridge is
no longer running. It knows which are which because the pid is in the
name, and it never touches one belonging to another live server.

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

The language servers need the same courtesy, and get less of it from
Neovim than it looks: on Linux no file watcher is registered for them by
default, so a file that another tool writes into the tree reaches a server
only when a buffer for it is opened. A Go file written with a plain Write
tool defines a name that gopls goes on calling undefined in every other
file of the package, while `go build` passes; that error is then
"pre-existing" on every later edit, and an agent that has been told to
trust the diagnostics stops trusting them. agent99 is the watcher instead:
before an edit is judged, and after `check_project` and `run_tests` have
run (both can generate files), every project directory is compared with
the disk by its mtime, and the files that appeared or vanished are relayed
to the servers as `workspace/didChangeWatchedFiles`. Files with an open
buffer reached their server already and are left out; a new directory git
ignores (build output) is not walked. When `check_project` passes while a
server still reports errors under the root, the reply says so under
`server_disagrees`, naming them, so the caller knows which of the two to
believe.

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

The most common way a server's diagnostics turn authoritative and wrong is
missing dependencies. A JavaScript or TypeScript project whose
`node_modules` is absent makes the server report a wall of
unresolved-import errors that are about the install, not the code; a
`node_modules` symlink pointing outside the workspace root can resolve a
package into a different checkout and produce a single plausible but wrong
type error. `open_workspace` warns about both in its reply, so a suspicious
import diagnostic is checked before it is believed rather than after.

A third case is a file whose language the attached server only appears to
share. QML's JavaScript libraries are `.js` files that may open with
`.pragma library` or `.import "Other.js" as Other` — QML's own directives,
and a syntax error to every other JavaScript parser, so tsserver answers
with "Declaration or statement expected" on line 1 and "Type assertion
expressions can only be used in TypeScript files" on line 2 of every one of
them, after every edit. Those errors say nothing about the code, and a
diagnostics block that is known to be wrong teaches a caller to stop reading
it, which is exactly when a real error slips past. agent99 recognises the
header, detaches the mismatched server and discards what it published. The
file stays a javascript buffer, so treesitter, the symbol index and the edit
tools work on it as before; an edit to it reports that nothing checked it
rather than that it is clean, and `check_project` runs `qmllint` over the
`.qml` files that import it, which is the gate that does apply.

### Extras

`AGENT99_LINT_<FILETYPE>` in the server's environment (`claude mcp add -e
AGENT99_LINT_GO="go vet {dir}" ...`) sets a post-edit linter without touching
the Neovim config; `{file}`, `{dir}` and `{root}` are expanded.

`AGENT99_FORMAT=range` (or `file`) turns on post-edit formatting for every
edit the server applies, the same switch as `post_edit.format` in `setup()`;
a call's own `format=` argument overrides both. The default is off.

`AGENT99_POST_EDIT_WAIT=0` makes every edit tool return as soon as the
text is in, the same switch as `post_edit.wait = false` in `setup()` and
`wait=false` on one call. The verdict then rides on the next reply,
whatever tool produces it (`grep` and `read_file` included), under
`deferred_verdicts`; a reply that comes before the server has answered
says so under `still_pending`, and an edit or a `diagnostics` read that
would otherwise take a snapshot settles what is owed first, so nothing is
charged to the wrong edit. Independently of that switch, diagnostics that
arrive after a report went out (a server re-checking the workspace on its
own schedule, lua_ls does so three seconds after a change) are carried in
the next reply under `late_diagnostics`, so a short estimate delays a
diagnostic rather than losing it.

What a format pass did comes back with the edit rather than having to be
found with `git diff`: `polished` says what ran, `polish_diff` is the
unified diff of what it changed, and `format_skipped` gives the reason a
pass was refused — the formatter changed the text inside a string literal
(an embedded shell script losing the indentation that is part of it), or it
ignored the indent options and re-indented the region to its own default.
In both cases the file keeps the text as the edit wrote it.

When `open_workspace` reports a language with no parser and no server, the
standalone server also offers `install_language(language)`: it installs the
tree-sitter parser through nvim-treesitter and a language server through
Mason (a sensible default per filetype, `server=` to pick another, `none`
for parser only), enables the server and checks that it attaches to a file
of that language in the workspace. When Mason has no package for the
filetype, or the package it lists has no build for this platform (qmlls on
aarch64), it looks for a server the machine already carries — an lspconfig
config for that filetype whose command is on PATH, including the versioned
name a distro installs it under, `qmlls6` for `qmlls` — and enables that
instead. Each step reports what it did or why it could not (no
nvim-treesitter or Mason in the config, a server whose toolchain is missing
such as `cargo` for rust_analyzer). Installed pieces
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
| `install_language` | standalone MCP only: tree-sitter parser via nvim-treesitter plus a language server via Mason for one filetype, enabled and attach-checked; falls back to a server already on the machine when Mason has no package or its package has no build for this platform (`qmlls6` for `qmlls` on aarch64); the fix for languages open_workspace calls blind |
| `debug_launch`, `debug_attach` | start a program under its debug adapter (Go, Python, C/C++/Rust built-ins, or a user nvim-dap configuration by name), or attach by pid or to a debug server by host/port, and wait for the first stop; `debug_launch()` with no arguments relaunches the previous configuration with breakpoints and `track` kept. `AGENT99_DEBUG=1` / `debug.enabled` advertises these |
| `debug_breakpoint`, `debug_breakpoints` | set/remove a breakpoint at a line or at a symbol name path plus offset (with `condition`, `hit_condition`, `log_message`), before or during a session; the reply says where the adapter actually put it. List or clear the agent's own breakpoints — the user's are never touched |
| `debug_continue`, `debug_step`, `debug_wait` | resume (or run to a line), step over/into/out `count` times, wait for a running program (`wait_ms=0` = just report, `pause_after` interrupts); every one replies with the stop context: frame with symbol, source window, locals, stack, output since the last reply, tracked expressions, stale-source warning |
| `debug_stack`, `debug_variables`, `debug_evaluate`, `debug_output` | the rest on demand: deeper stack with external frames collapsed, variables of a frame one level deep or one path expanded, an expression in a frame, and the captured output (up to 200 lines, surviving the exit) |
| `debug_stop` | terminate a launched program or disconnect from an attached one (left running unless `force`), remove the agent's breakpoints, kill the adapter if it lingers |
| `install_debugger` | standalone MCP only: delve, debugpy, codelldb, js-debug-adapter or java-debug-adapter through Mason, for a language whose `debugger` field says none |
| `workspace_tree` | the directory structure with aggregated stats, cut to a line budget (40 by default, `budget=` up to 400): each directory with its file and line counts, its languages, test count, biggest files and hidden subdirectories, and the files that matter most listed under it; in a project of 40 files or fewer, declaration counts too. Root files come first (a Makefile or go.mod is what tells the project apart), then directories largest first, then the remaining files ranked by size discounted per level, so a file two levels down needs four times the lines of a top-level one to earn a line. Chains of single-child directories collapse to one line (`lua/agent99/`), binaries are counted and never listed, and a directory holding one file is shown as that file. One `git ls-files` and one `wc` pass, so a monorepo answers in a quarter of a second. `open_workspace`'s reply carries the root's tree; `path=` zooms into a directory and `depth=` (default 2) goes further down |
| `workspace_map` | the shape of a directory or the whole workspace: every project file with its line count and its declarations, descending one level into classes so nested languages list their methods (string parsers on disk content — no buffers created, no servers attached); the outline budget is shared across files (`+N more` marks a cut); in a project of more than 40 files test files are left out unless `include_tests` (a small project's tests are its spec, so they stay in); the move after `workspace_tree` has named the directory that matters, ahead of skim/grep. Markdown files list their headings |
| `skim` | structure of up to 20 files in one call: every function/class/method declaration line with line numbers, nested (treesitter, LSP-symbol fallback; C/C++ take the server's symbols first because macros confuse the grammar) — measures ~6-25% of the tokens of reading the same files. Markdown headings index like declarations, so a README's sections are name paths (`Install/Requirements`) for `find_symbol`, the section edits and grep's hit tags. Data files index by key the same way: a compose file's `services/api/environment`, a TOML `[server]` table, a JSON object's members, a Dockerfile's build stages (`FROM … AS runtime` up to the next `FROM`); lists are not descended into. A file that declares nothing falls back to the server's symbols, where an array's elements arrive as one symbol each named after their own text: those are left out of the outline and counted, so a Lua table of package names outlines as its keys rather than as thirty strings. Build files too: a Makefile's targets and variables are symbols (`smoke` is the target with its recipe), and a shell script's are its functions and the variables it sets at the top — an assignment further in is a statement, not a declaration of the file. A QML file outlines as its object tree — the `Item`s, properties and signals, not only its JS functions — and a callback written as a single expression (`(store) => store.setPrompt`, which half a React file is made of) is not a declaration and is left out. A long file whose outline is trivial (one top-level key) is read as text rather than answered with the outline |
| `find_symbol` | look up symbols by `/`-joined name path, optionally returning the full body — fetch exactly one function instead of a whole file. `file`, `files` and `glob` narrow the search; with none of them it covers the whole workspace, ripgrep first cutting it down to the files that spell the name at all, since a file that never writes the name cannot declare it. Constants and module-level variables are included by folding in the server's document symbols, which treesitter's declaration nodes leave out. A name path that matches nothing answers with `count: 0` and `suggestions` (the symbols sharing its last segment), never with fuzzy matches that read like the symbol being found somewhere else |
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
| `replace_pattern` | the same textual change in many places, for the bulk edits a rename cannot express: a call site's receiver changes (`root.finiteNum(x)` becomes `Sanitize.finiteNum(x)`), an argument is added, a constant is spelled differently. The identifier the server knows does not change at all, so `rename_symbol` has nothing to offer, and one `replace_symbol_lines` chunk per site is not a real option at a hundred sites — which used to mean leaving for a shell `sed`, outside the buffers, the undo ledger and the diagnostics. The pattern is a Vim regex in very magic mode (close to an extended regular expression, with `\1`..`\9` in the replacement) or plain text with `literal=true`; it is case sensitive whatever `'ignorecase'` happens to be, and matches within one line. `kind=code` leaves matches inside comments and string literals alone, which is the thing a regex cannot do on its own, and `tests=` splits production code from tests on the path. `dry_run` reports the per-file counts and sample lines without touching anything. Very magic mode reads `=` as "the atom before it is optional" and `<`/`>` as word boundaries, so an alternation of lines of code has branches that quietly match nothing while the reply still reports the files the other branches matched: each branch is counted on its own and the dead ones are named with that explanation, and a single pattern that matched nothing gets the same note. Applied edits enter the undo ledger per file and the reply carries the servers' verdict like any other edit |
| `run_tests` | the project's tests as a tool, so the edit-check-test loop stays inside agent99 (a runner with no parser of its own is read for failures only when it exited non-zero, since prose about a `ResourceWarning` from the standard library was otherwise counted as three failing tests next to the runner's own `OK`; `python -m unittest` has a parser now, and a filter that matched no test reads as "no tests ran" rather than as passing): runs the runner from the root and answers with what failed rather than a page of output. Each failure carries its test name, file, line, message and the test symbol it sits in (so `find_symbol(name_path=...)` reads it and `run_tests(filter=...)` reruns it alone), plus the runner's pass and fail counts. The first call in a root records a baseline of failing test names; later calls report which tests started failing and which stopped, so durations and temp paths never count as change. Without arguments it uses the command remembered for the root, `AGENT99_TEST`, `post_edit.test`, or a guess from the project's files: a Makefile `test` target first (it is what CI runs), then `go test ./...`, pytest, the package.json test script through the lockfile's package manager, `cargo test`, busted. `path=` narrows to a directory or file and `filter=` to a test name where the runner has a way to take them (`-run`, `-k`, `-t`, cargo's positional filter); those go to the guess, since a remembered command has no slot for them. `command=` runs your own and `remember=true` keeps it for the root across sessions. Output is parsed for go test, pytest, jest/vitest and cargo, and sniffed for a Makefile target that turns out to run one of them; a build failure under go test is reported as such instead of as zero failures |
| `check_project` | one project-wide check from the root (`post_edit.check`, `AGENT99_CHECK`, or guessed from go.mod / tsconfig.json / Cargo.toml, `pyright` or `mypy` for a project with `.py` files whether or not it has a pyproject.toml, `luacheck` or `luac -p` for `.lua`, `qmllint` over the `.qml` files of a project that has them, and a headless `nvim` start for the configuration this Neovim loads, whose real breakage is load-time and invisible to a static check — guessed only when the root *is* `stdpath("config")`, since `nvim -u <root>/init.lua` anywhere else sources that init while every `require` and every `plugin/`/`after/plugin/` script still resolves out of the real config directory, and the check would call a broken copy clean); the first call in a root records a baseline, later calls report only new and resolved lines. The qmllint guess comes with what a Qt project otherwise learns the hard way: qmllint exits 0 on warnings and the flag that changes that (`-W`) does not exist on older Qt, so the new lines are the gate rather than the exit code |
| `unreferenced_symbols` | the top-level symbols of a file that nothing outside their own body mentions. The check an extract-to-module refactor needs and nothing else provides: a definition left behind after its callers moved is not an error to a language server and not a warning to a linter, so every edit along the way honestly reports "no new errors" and the dead copy ships. It asks `textDocument/references` where a server answers it and falls back to a whole-word project search where none does (QML is one), and says which it used. That search looks for the name as it is written at a call site: a Go method indexed `(*Archiver).Do` is called `a.Do(...)`, and searching the qualified spelling matched nothing, so every method in a file came back unreferenced. References from test files do not count as uses unless `include_tests` — except for a symbol declared in a test file, which is used by tests by design and would otherwise report every fixture in the repository as dead. A public API, a name reached by reflection or used from a build configuration the search cannot see lands here too, so a finding is something to read before deleting |
| `undo_edit` | take back the newest edit(s) of the run (`count`, or `all`), restoring the recorded source, or reversing a create/move/delete. One tool call is one step, however many files it wrote. It refuses when the region changed since — and `skip=true` forgets that entry and undoes the ones under it, which used to need `git checkout`. A language server's own code action is not covered, but an action offered by a refused edit is — it re-runs that edit tool — and a destination `move_symbols` created goes with the move rather than surviving as an empty stub |
| `replace_symbol_body`, `replace_symbol_lines`, `insert_after_symbol`, `insert_before_symbol`, `insert_lines` | symbol-addressed edits, applied to editor buffers immediately and tracked (undoable per run). The two replacements take `dry_run` and return a unified diff without applying, the way `rename_symbol` always has. A name path several declarations answer to takes `line=` (the declaration line, which `find_symbol` prints) to pick one, and the refusal lists each candidate's line rather than the same name three times. `files=` makes the same edit in each of several files, in one call and one undo step. `replace_symbol_lines` addresses the lines three ways: `match=`, the lines to replace as they are now (whole lines, occurring once in the symbol; no line arithmetic, the preferred form); `first_line`/`last_line` relative to the symbol's declaration as `find_symbol` numbers them; or the same with `absolute=true`, as `read_file`, grep hits and `buffer_lines` report lines. With line numbers, `expect=` is the text those lines currently hold, so a number that went stale is refused instead of overwriting working code (numbers relative to the declaration are re-anchored on every call and survive an edit above the symbol; `absolute=true` numbers survive nothing above them, and either kind is moved by an earlier edit inside the same symbol); when that text sits in exactly one other place the edit is applied there and the reply's `relocated` field says where it went and what the requested lines held (every later number for that file is stale too, so re-read or switch to `match=`); when it is nowhere, or in several places, the call is refused with what was found, and a `force=true` code action is offered for the caller who meant the requested lines anyway. An `expect=` that covers a different number of lines than the range is refused rather than relocated, whatever its text says: relocating it would apply the edit to those lines alone, so a 79-line replacement guarded by its own first line would become a one-line replacement with the other 78 left below the new text. The refusal names both counts, says whether the range does start with the expected text, and offers the narrowing as a code action instead of taking it — but only when the text the call carried fits the lines the `expect` covers. Text written for the whole range is offered no narrowing at all: dropping six lines onto the one line that was quoted leaves the other five below them, which is the duplication the refusal exists to prevent, reached through the fix it suggested. For that call the action that matches the text is applying it at the requested lines. A region with no symbol — a barrel or index file, an import block, an export list — is editable by leaving `name_path` off and giving `absolute=true` numbers or a `match`, the case that used to force a fall back to a whole-file write. A `name_path` the file does not declare is refused with the closest names it does declare, so a near miss is corrected from the refusal rather than from a `find_symbol` round trip; a file whose declarations nothing can parse says that instead, since no name path will ever resolve there and its lines have to be addressed directly. Several places in one file go in `chunks`, each naming its own symbol or none (the call's `name_path` is the default for every chunk that names none; a chunk whose `match` sits once outside that symbol, in the const block above the function say, is applied where the text is and reported under `relocated`), applied together bottom-up, with each region formatted on its own so the code between them is untouched; offsets and expect texts are checked together and the call is refused as a whole if any fails (what the new text means is the language server's verdict afterwards, like any edit). It also echoes back what it replaced, and `verify=true` echoes the bytes that landed as well — text that came through a JSON round trip can carry an escape the caller never meant, and a control character among the written bytes is reported without being asked for. `insert_before_symbol` lands above the symbol's decorators, attributes and doc comment, never between them and the declaration. `insert_lines` is the insert with no symbol to anchor it: `line=N` puts the text above that line (`at="start"`/`"end"` without knowing the file's length), which is the file whose first statement is a bare call, and `files=` takes the same text to several files in one call — one guard prepended to a directory of them, which used to mean a shell `cat`. When a formatter changes lines beyond the edited region (lua_ls drops a blank line after a function that shrank), the ledger folds them in, so `undo_edit` restores the file exactly. After every edit imports are organized (a new call into an unimported package costs no extra round, and only a real `source.organizeImports` action is applied so the server never appends a stub for an unresolved name). Formatting is off unless asked for: `format="range"` on the call (or `post_edit.format` / `AGENT99_FORMAT` as the default) runs the server's formatter over the edited lines, confined to them even where the server only offers whole-file formatting, so a change to a file that was never formatter-clean stays a small diff, and `format="file"` formats the whole file; without it the text lands byte for byte, which is what most agents expect of an edit tool. A pass that changed the text inside a string literal, or re-indented the region to a width the file does not use, is taken back and reported in `format_skipped` instead of being applied; a pass that is kept comes back as `polish_diff`. `lines` names where the written text now is, measured from the diff of the pass rather than from a mark, which a server answering a range format with edits for the whole document would collapse. Then the tool waits for the servers' verdict (a cheap request sent with the edit proves the server took it in, so a push-only server that stays silent because nothing changed costs `settle_ms`, not the `wait_ms` ceiling; how long each server takes to publish after acknowledging is measured through the session and the settle follows it) and returns only the errors/warnings the edit introduced, plus new errors in other open files and optionally a linter's output (see `post_edit`). The pre-existing diagnostics are a count with a delta: what the last reply listed is remembered per diagnostic, an entry new to the list (an error the caller's own earlier edit planted, pre-existing now) is named under `preexisting_new_to_list`, the rest stays a count, and a list with nothing new is one short line; `full_diagnostics` lists them all again. A pointer to that switch goes out once per session, not on every reply |
| `move_symbols` | move whole symbols from one file into another, each with its doc comment, reorganizing the imports of both afterwards — the way to split an oversized file, which no other symbol tool can express because the unit is a run of independent declarations rather than one symbol. Creates the destination if missing (inferring a `package X` header where the language has one), and is undoable |
| `create_file`, `move_file`, `delete_file` | file lifecycle through the language servers (`workspace/*FileOperations`), so a refactor that adds, splits or renames a file does not have to leave the editor. `move_file` has the server rewrite the imports naming the old path before the move; `create_file` makes parent directories, formats and organizes imports, and refuses to overwrite; `delete_file` reports what broke elsewhere. All three are undoable through `undo_edit` |
| `buffer_lines` | editor's live buffer content, **including unsaved changes** |
| `grep` filters | `kind=` keeps only definitions, calls, comments, strings, or `code` (anything that is not a comment or a string) — the fix for an identifier that also appears in the prose above every use of it; `tests=exclude`/`only` splits production code from tests on the path. Filtering by kind implies no context lines, and says how many hits were never classified rather than quietly dropping them |
| `read_file`, `grep`, `list_files` | plain file access rooted at the project (openai-kind providers; claude brings its own Read/Grep/Glob). A plain read of a large file returns its skim instead of thousands of lines. A file holding a NUL byte stops the searcher at its first match — a source file with one stray NUL was searched no further — so those files are named in the reply and `text=true` searches them in full. Grep output is deterministic and every hit is annotated: `file:line [Symbol kind @pos/len dN !SEV ~age · signature · doc-comment]` — what the hit *is*, where it sits, its nesting depth, existing diagnostics, `test:` for test files, blame age on request — so most hits need no follow-up read |

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

It runs four suites in turn: `mcp` (the bridge attached to a live Neovim,
`tests/drive_mcp.py`), `headless` (the standalone server and every edit
tool, `tests/drive_headless.py`), `multi` (several workspaces at once) and
`debug`. Naming suites narrows the run while iterating: `tests/smoke.sh
headless`, or `make smoke SUITES="headless multi"`. A partial run says so
on its last line; run the full suite with no arguments before committing,
because the suites share the Lua and the bridge and a change that passes
one can still break another. The `headless` suite is the longest (some
35 edit calls against lua_ls, about 40 s); `multi` and `debug` together
run in under half a minute, the whole set in about a minute.

`tests/drive_multi.py` opens two copies of `tests/testproj` side by side
and checks the routing between them: the overlap and limit refusals, an
absolute path reaching its own workspace, `workspace=<root>`, a relative
path following the active one, a refused cross-workspace `move_file`, an
`undo_edit` that follows the edited workspace rather than the last read,
and closing one instance without disturbing the other.

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
- Workspaces may not overlap: a root inside (or around) an open one is
  refused, so a monorepo is opened once, at one level. Closing a workspace
  takes its loaded buffers and `check_project` baseline with it; a check
  command remembered with `remember=true` survives, per root, under
  Neovim's state directory.
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
