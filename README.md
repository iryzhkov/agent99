# agent99

Agentic code edits in Neovim with LSP-aware context gathering, in the style of
[ThePrimeagen/99](https://github.com/ThePrimeagen/99): select a region, give an
instruction, and an LLM agent proposes a rewrite of the selection. The twist is
that the agent gets tools backed by the LSP clients **already running inside
your Neovim** — definition, references, hover, symbols, diagnostics, call
hierarchy, code actions, and the unsaved state of your buffers — so it can
explore the codebase the same way you do, with a warm index and no extra
language-server processes.

![The agent panel: tool activity streams while the agent explores, and the
code window follows what it reads](doc/panel-chat-working.png)


## How it works

```
Neovim (your editor, LSP clients attached)
  │  <leader>9v on a visual selection → instruction prompt
  │  spawns bin/agent99-bridge (one static Go binary, stdlib only)…
  ├─ agent99-bridge agent             (provider "openai", default: DeepSeek)
  │    OpenAI-compatible function-calling loop.
  │    LSP tools call back into Neovim over a NON-BLOCKING protocol:
  │    `--remote-expr Agent99RpcStart(...)` kicks off the tool in a coroutine
  │    and returns immediately; the bridge polls Agent99RpcPoll(...) for the
  │    result, so the editor UI never freezes during a tool call.
  │
  └─ or `claude -p` + agent99-bridge mcp      (provider "claude")
       Same LSP tools exposed as an MCP stdio server.
       Note: consumes your Claude subscription/API quota; no follow-ups.

  The agent's reply (wrapped in <replacement> tags) shows up in a preview
  split — <CR> applies it over the selected lines, q discards. Extmarks
  track the region, so edits elsewhere in the buffer while the request
  runs don't corrupt the target range.
```

The bridge is a single Go binary with no dependencies outside the standard
library (no pynvim, no MCP SDK, no HTTP client library). Build it once with
`make build`. The Lua side of the RPC lives in `lua/agent99/lsp.lua` and
reuses whatever clients are attached; files not yet open are loaded into
hidden buffers, which triggers normal LSP attach.

## Install

lazy.nvim:

```lua
{ "iryzhkov/agent99", build = "make build", opts = {} }
```

or from a local clone: `{ dir = "~/src/agent99", opts = {} }` (run
`make build` there once).

### Providers

`provider` is a preset name, a preset with overrides, or a full table:

```lua
provider = "deepseek"                     -- built-in preset (the default)
provider = { preset = "ollama", base_url = "http://my-gpu-box:11434/v1",
             model = "qwen2.5-coder:14b", temperature = 0.2 }
provider = { base_url = "https://my.gateway/v1", model = "my-model",
             api_key_env = "MY_KEY" }    -- no preset at all
```

Built-in presets: `deepseek`, `openai`, `openrouter`, `ollama` (local, no
key), `claude` (spawns `claude -p` over MCP; uses your Claude quota, no
chat/follow-ups). Define your own under `providers` and refer to them by
name:

```lua
providers = { mylab = { base_url = "http://mylab:8000/v1", model = "m", api_key = "x" } },
provider = "mylab",
```

`:Agent99Provider <name>` switches presets at runtime (tab-completes;
no argument shows the active provider) — e.g. a cheap default for chat and
`:Agent99Provider claude` for a hard edit.

Provider fields (all overridable per preset): `kind` (`"openai"` for any
OpenAI-compatible chat-completions API, `"claude"`), `base_url`, `model`,
`api_key` / `api_key_env` / `keyring_service` (resolution order; see below),
`temperature` (default 0.0), `max_tokens`, `max_rounds` (30), `full_tools`
(advertise the full tool roster, see below), and for claude: `claude_cmd`,
`allowed_tools`.

### Options

```lua
require("agent99").setup({
    -- everything below is the default
    provider = "deepseek",
    providers = {},              -- your own presets, by name
    chat_provider = nil,         -- preset the panel falls back to when the main
                                 -- provider cannot chat (e.g. "deepseek" with a
                                 -- claude main provider)
    preview = true,              -- proposal split with <CR> apply / q discard
    auto_fix = true,             -- new ERRORs after an apply trigger one automatic fix round
    auto_fix_delay_ms = 2000,
    context_full_file_max = 200, -- embed whole file in the prompt up to this size
    context_lines = 50,          -- else this many lines around the selection
    timeout_ms = 5 * 60 * 1000,
    history = { keep = 100 },    -- request records kept on disk
    ui = { width = 0.4, input_height = 5 },
    keymaps = {                  -- false disables all; set a key to false to drop one
        toggle_panel = "<leader>99",    -- n
        panel_selection = "<leader>99", -- x
        edit = "<leader>9v",            -- x
        ask = "<leader>9a",             -- x
        followup = "<leader>9f",
        cancel = "<leader>9x",
        history = "<leader>9h",
        logs = "<leader>9l",
    },
    bridge_bin = nil,            -- default: <plugin>/bin/agent99-bridge
})
```

Requirements: Neovim ≥ 0.11, Go (build time only — `make build` in the plugin
directory produces `bin/agent99-bridge`), an API key, and working LSP in the
buffers you edit. A missing binary is reported with a clear error on first
use.

**API key resolution**: a literal `api_key` in the provider wins (meant for
local servers, not real secrets); then the configured environment variable;
then the key is read from the system keyring via
`secret-tool lookup service <keyring_service>` (libsecret). Store it from
inside Neovim with `:Agent99SetKey` — it prompts with concealed input and
writes to the keyring, no dotfile plain text. A request without any
resolvable key fails immediately with an error message instead of spawning
the agent.

## Use

### The agent panel (`<leader>99`)

The primary interface: a vertical split on the right with a scrolling
conversation pane above a prompt buffer, while the window you started from
stays on the left as the code window.

![A finished answer in the panel, with file:line citations and the cost
line](doc/panel-chat.png)

- `<leader>99` toggles the panel; `<CR>` in the prompt (or `<C-s>` in insert
  mode) sends; `i` in the conversation pane jumps to the prompt; `q` hides
  the panel without losing anything.
- The conversation persists for the whole Neovim session — `gn` or
  `:Agent99Clear` is the explicit reset.
- Everything streams live: tool activity as it happens, and the answer
  itself token-by-token (SSE), followed by a cost line
  (`3 rounds · 11.2k in (94% cached) …`).
- The pane renders as markdown (treesitter + conceal; if
  render-markdown.nvim is installed it picks the pane up automatically for
  fully rendered headings/bullets/code blocks).
- `/help` in the prompt lists panel commands: `/clear`, `/revert`,
  `/cancel`, `/stats`, `/history`, `/hide`.
- The code window follows the agent: deliberate reads (read_file,
  buffer_lines, find_symbol bodies) move it to the file and position being
  read; edits jump it there with a brief highlight. Edits land unsaved in
  buffers; `:Agent99Revert` (or `/revert`) undoes the last batch.
- `<leader>99` from a visual selection stages the selection (file, range,
  text) as context for the next message — including mid-conversation: leave
  the panel, select something else in any file, hit `<leader>99` again, and
  the conversation continues with the new context attached.
- Chat mode needs the openai provider (transcript continuity).

### Region flows

![While the request runs, the selected region is highlighted with a working
marker](doc/edit-working.png)

![The proposal opens in a preview split: apply with CR, discard with
q](doc/edit-preview.png)

- Visually select lines, press `<leader>9v`: a telescope-style compose
  picker opens — selection list top-left (the first entry is the edit
  target), instruction prompt below it, and a syntax-highlighted preview
  of the highlighted selection on the right. Type the instruction and
  `<CR>` (insert: `<C-s>`) to send. The draft is sticky: `q`/`<Esc>`
  closes the picker without losing it, and invoking `<leader>9v` (or
  `9a`) again from another selection — any file — stacks that selection
  as additional context instead of starting over, so one request can
  carry several regions. Navigate with `<C-j>`/`<C-k>` from the prompt or
  `<Tab>` into the list and `j`/`k`; `x` removes a context, `gx` discards
  the draft and the stack. While the request runs the target region is
  highlighted (`Agent99Working`, links to `Visual`) with an
  `agent99 working…` marker; when the agent finishes, the proposal opens
  in a preview split — `<CR>` applies it, `q` discards (or is applied
  directly with `preview = false`).
- `<leader>9a` asks a question about the selection instead of editing it:
  the agent investigates with the same tools and the answer opens in a
  markdown split (`q` closes it), with locations cited as file:line.
- `<leader>9f` follows up on the last edit **or answer**: the agent keeps its
  full conversation (everything it already learned about your code) and
  targets the discussed region, even if you have edited elsewhere since.
  This is the ask-then-act flow: discuss with `<leader>9a`, then "now do it"
  with `<leader>9f`. Openai-provider only.
- `<leader>9x` (or `:Agent99Cancel`) cancels an in-flight request, or
  discards a pending preview.
- `<leader>9h` (or `:Agent99History`) lists past requests; `<CR>` on a line
  opens the stored record (instruction, result, transcript path).
- `<leader>9l` (or `:Agent99Logs`) opens the log, including a per-request
  trace of every tool call the agent made and token usage per round.

The selection is the agent's main context and its primary edit target, but
it is not the boundary: changes that belong elsewhere (a helper below an
existing function, an import, another file) are made through the
symbol-addressed edit tools during the run, land in editor buffers
(unsaved), are listed in the completion notification, and can all be undone
at once with `:Agent99Revert`.

Safety and feedback around an apply:

- A line-numbered snapshot of the file (or a window around the selection) is
  embedded in the initial prompt, so the agent usually skips a read round.
- When a request finishes, a stats line is shown: rounds, tokens in/out,
  wall-clock seconds (also stored in the history record).
- If the selected region changed while the agent worked, the apply is
  refused and the proposal is kept in history (hash guard).
- After an apply, agent99 waits `auto_fix_delay_ms`, compares ERROR
  diagnostics against the pre-edit set, and if the edit introduced new ones,
  automatically runs one follow-up round asking the agent to fix them
  (openai provider; never chains a fix-of-a-fix).

Every request — successes and failures alike — is persisted as a JSON record
under `stdpath("state")/agent99/history/` (pruned to `history.keep`), with
its outcome `status` (applied / discarded / stale_refused / no_replacement /
error / empty_reply / cancelled / answered), per-tool call counts, rounds,
token totals, duration, and the full agent transcript alongside.
`:Agent99Stats` (or `/stats` in the panel; session-scoped, `all` for
lifetime) aggregates them: outcome rates, average cost per request,
tool-usage breakdown, and recent failures — the data to judge what to
improve next. The records are plain JSON, so deeper analysis is a `jq` away.

## Tools exposed to the agent

| Tool | Backed by |
|---|---|
| `definition`, `type_definition`, `implementation` | `textDocument/*` via live client |
| `hover` | `textDocument/hover` (signatures + docs) |
| `expand_symbol` | definition + full source of the defining symbol + hover, in one round-trip |
| `workspace_map` | the whole workspace's shape in one call: every project file with its line count and top-level declarations only (string parsers on disk content — no buffers created, no servers attached); the intended first move in an unfamiliar repo, ahead of skim/grep |
| `skim` | structure of up to 20 files in one call: every function/class/method declaration line with line numbers, nested (treesitter, LSP-symbol fallback) — the intended first move when exploring; measures ~6-25% of the tokens of reading the same files |
| `ts_query` | structural multi-file search: a treesitter s-expression query over a file list or glob, with `@captures` and `#eq?`/`#match?` predicates — for questions grep can't ask (declaration vs usage, match by shape); a non-compiling query returns a clear error pointing at skim |
| `find_symbol` | look up symbols by `/`-joined name path across files/globs, optionally returning the full body — fetch exactly one function instead of a whole file |
| `replace_symbol_body`, `replace_symbol_lines`, `insert_after_symbol`, `insert_before_symbol` | symbol-addressed edits, applied to editor buffers immediately and tracked; `replace_symbol_lines` edits a slice by symbol-relative line numbers (the numbering `find_symbol` bodies use), so small changes in big functions cost only the changed lines. Every edit tool returns fresh post-edit diagnostics in its own result. The user reverts the whole batch with `:Agent99Revert`; the selection itself stays reserved for the `<replacement>` reply |
| `document_symbols` | file outline (LSP symbols, each with its declaration line) |
| `workspace_symbols` | project-wide symbol search |
| `diagnostics` | `vim.diagnostic.get` (what the editor shows); each error/warning also lists the `quick_fixes` the language server can apply itself, steering the agent to `apply_code_action` instead of hand-writing fixes |
| `incoming_calls`, `outgoing_calls` | call hierarchy (server support varies; lua_ls lacks it) |
| `code_actions`, `apply_code_action` | list the editor's quick fixes/refactorings, apply one by token+index; the edit is performed by Neovim itself (safe, possibly multi-file) |
| `buffer_lines` | editor's live buffer content, **including unsaved changes** |
| `references` | `textDocument/references`, each hit annotated with its enclosing symbol path |
| `read_file`, `grep`, `list_files` | plain file access rooted at the project ("openai" provider; the claude provider uses its own Read/Grep/Glob). A plain `read_file` of a large file returns its skim instead of 2000 lines. Grep takes `glob`, `context`, and `blame` arguments and annotates every hit: `file:line [Symbol kind @pos/len dN !SEV ~age · signature · doc-comment]` — what the hit *is* (def/call/comment/string), where it sits in its symbol, how deeply nested, whether the line already carries a diagnostic, `test:` for test files, when it last changed (blame, partial-clone-safe), with signature+doc shown once per symbol. Partial reads (`read_file` offset, `buffer_lines` first/last) are prefixed with a breadcrumb naming the enclosing symbol |

Positions are addressed as `(file, line, symbol-text-on-that-line)` instead of
raw columns — far more reliable for an LLM, with UTF-16 conversion handled on
the Lua side.

**Slim default roster**: `type_definition`, `implementation`,
`incoming_calls`, `outgoing_calls`, `document_symbols`, and `expand_symbol`
are not advertised by default (near-zero measured usage; skim/find_symbol
cover them), saving ~1k prompt tokens per round. They remain callable, and
`full_tools = true` (or `AGENT99_FULL_TOOLS=1` for the MCP server)
re-advertises them.

## Tests

```
make build   # compile bin/agent99-bridge (Go, stdlib only)
make smoke   # bridge + all LSP tools against a headless nvim + lua_ls; free
make e2e     # one real agent edit through DeepSeek; needs DEEPSEEK_API_KEY
```

`tests/smoke.sh` starts a throwaway headless Neovim with a minimal config
(`tests/minimal_init.lua`, native vim.lsp.config, no lspconfig) on the bundled
`tests/testproj`, then asserts on real lua_ls results through the MCP bridge.
lua-language-server must be on PATH or in mason's bin directory.

## Known limitations

- One request at a time.
- The reply replaces the selection; agent-driven multi-file editing exists
  only through `apply_code_action`.
- First LSP query in a cold project can return empty results while the server
  is still indexing; the agent usually retries (the smoke test does too).
- Auto-fix compares diagnostics by severity+message, so a pre-existing error
  message that the edit duplicates on another line still counts as new, and
  an edit that merely moves an error is not flagged.

## Ideas / next steps

- Hunk-based diff preview (show only what changed, via vim.diff).
- Streaming tool-call progress into the virtual text.
- Charwise/blockwise selections (currently widened to whole lines).
- `textDocument/rename` as an agent tool (safe multi-file refactor primitive).
- FIM-based ghost-text completion as a separate fast path.
