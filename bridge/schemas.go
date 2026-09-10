package main

// Tool schemas: what the model is shown for every tool. The execution lives
// in tools.go (file tools) and in the plugin's Lua (everything routed
// through Neovim). Keep descriptions short; every advertised schema costs
// prompt tokens on every round.

import (
	"fmt"
	"os"
)

type tool struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

// Tools in this set are still executable but are left out of the default
// ("slim") schema advertised to the model, because skim and find_symbol
// genuinely cover them and every advertised schema costs prompt tokens on
// every round. Restore them with provider.full_tools = true (agent) or
// AGENT99_FULL_TOOLS=1 (MCP server).
//
// Keep this list short and justify each entry. It was previously trimmed on
// "measured usage is near zero", which is circular for a tool the model is
// never shown: a session tracing a bug asked for a call-hierarchy tool and an
// implementations tool as missing features while both sat here, implemented
// and invisible. A tool that is hidden is a tool that does not exist.
var extraTools = map[string]bool{
	"install_language": true, // standalone MCP advertises it regardless
	"document_symbols": true, // skim is the same information, nested
	"expand_symbol":    true, // find_symbol include_body, plus a hover
}

func activeTools(all []tool, full bool) []tool {
	if full {
		return all
	}
	var out []tool
	for _, t := range all {
		if !extraTools[t.Name] {
			out = append(out, t)
		}
	}
	return out
}

func positionSchema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"file":   map[string]any{"type": "string", "description": "File path (absolute or relative to root)."},
			"line":   map[string]any{"type": "integer", "description": "1-based line number."},
			"symbol": map[string]any{"type": "string", "description": "Symbol text on that line, first occurrence. Prefer over col."},
			"col":    map[string]any{"type": "integer", "description": "1-based byte column, alternative to symbol."},
		},
		"required": []string{"file", "line"},
	}
}

func positionTool(name, description string) tool {
	return tool{Name: name, Description: description, InputSchema: positionSchema()}
}

func fileOnlySchema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"file": map[string]any{"type": "string", "description": "File path (absolute or relative to root)."},
		},
		"required": []string{"file"},
	}
}

// lspTools are executed inside Neovim, against its live LSP clients.
var lspTools = []tool{
	positionTool("definition",
		"Definition of the symbol at a position, with a line preview."),
	positionTool("type_definition",
		"Type definition of the symbol at a position."),
	positionTool("implementation",
		"Implementations of the interface/abstract symbol at a position."),
	positionTool("references",
		"Every reference to the symbol at a position, project-wide, grouped by file, each tagged with its enclosing symbol. Check before changing a signature."),
	positionTool("hover",
		"Signature and docs of the symbol at a position, as the editor shows them."),
	positionTool("expand_symbol",
		"Definition of the symbol at a position plus the full source of the defining symbol and its hover, in one call."),
	positionTool("incoming_calls",
		"Callers of the function at a position (call hierarchy)."),
	positionTool("outgoing_calls",
		"Functions called by the function at a position (call hierarchy)."),
	positionTool("code_actions",
		"LSP code actions at a position (quick fixes, refactors): a token plus indexed titles for apply_code_action."),
	{
		Name:        "apply_code_action",
		Description: "Apply one action from code_actions by token and index. The editor performs the edit (possibly multi-file). Changes stay unsaved in editor buffers - inspect them with buffer_lines.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"token": map[string]any{"type": "string", "description": "Token returned by code_actions."},
				"index": map[string]any{"type": "integer", "description": "1-based index of the action to apply."},
			},
			"required": []string{"token", "index"},
		},
	},
	{
		Name:        "skim",
		Description: "Structure of up to 20 files in one call: every declaration line, nested, with line numbers. Use before reading a file, then read only what matters.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"files": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "1-20 file paths.",
				},
			},
			"required": []string{"files"},
		},
	},
	{
		Name:        "install_language",
		Description: "Install the treesitter parser (nvim-treesitter) and a language server (Mason) for a filetype into this Neovim. Use when open_workspace reports a language with neither. Slow; once per language.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"language": map[string]any{"type": "string", "description": "Filetype (go, python, typescript, cpp) or a file extension."},
				"server":   map[string]any{"type": "string", "description": "Mason package or lspconfig name instead of the default; none = parser only."},
				"parser":   map[string]any{"type": "boolean", "description": "false = server only."},
			},
			"required": []string{"language"},
		},
	},
	{
		Name:        "workspace_tree",
		Description: "The directory structure with aggregated stats (files, lines, languages, tests, biggest files) and the files that matter most, cut to a line budget; in a small project declaration counts too. open_workspace's reply carries the root's tree; call this to zoom into one directory (path=) or see more (depth=, budget=). Cheaper than workspace_map by orders of magnitude on a big repo: it reads no file contents beyond a line count.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"path":   map[string]any{"type": "string", "description": "Subdirectory to start from (default: root)."},
				"depth":  map[string]any{"type": "integer", "description": "Directory levels to show (default 2; a chain of single-child directories counts as one)."},
				"budget": map[string]any{"type": "integer", "description": "Lines of output (default 40, max 400). Directories go first, then files ranked by size discounted per level."},
			},
			"required": []string{},
		},
	},
	{
		Name:        "workspace_map",
		Description: "Every project file with its line count and declarations - classes with their methods one level in - in one cheap call. The first move in an unfamiliar repo. In a big project test files are left out unless include_tests; a small one lists them.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"path":          map[string]any{"type": "string", "description": "Subdirectory (default: root)."},
				"glob":          map[string]any{"type": "string", "description": "Path glob relative to the root, e.g. src/**/*.go; subdirectories need a **/ prefix."},
				"include_tests": map[string]any{"type": "boolean", "description": "List test files too (default: only when the project has 40 files or fewer)."},
			},
			"required": []string{},
		},
	},
	{
		Name:        "ts_query",
		Description: "Structural search: a treesitter s-expression query with @captures (#eq?/#match? allowed) over many files. Node names are grammar-specific; skim first if unsure.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"query": map[string]any{"type": "string", "description": "Treesitter query (s-expression) with at least one @capture."},
				"files": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "Files to search (optional if glob is given).",
				},
				"glob": map[string]any{"type": "string", "description": "Path glob relative to root, e.g. **/*.go; subdirectories need a **/ prefix."},
			},
			"required": []string{"query"},
		},
	},
	{
		Name:        "find_symbol",
		Description: "Find symbols by name or name path (\"Class/method\"; suffix and substring match), across the whole workspace or narrowed to files/glob, optionally with full source (include_body) numbered relative to the symbol, ready for replace_symbol_lines. Cheapest way to read one function.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"name":         map[string]any{"type": "string", "description": "Name or name path; suffix/substring match."},
				"file":         map[string]any{"type": "string", "description": "One file to search (default: the whole workspace)."},
				"files":        map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "Several files to search."},
				"glob":         map[string]any{"type": "string", "description": "Path glob relative to root, e.g. **/*.go; subdirectories need a **/ prefix."},
				"include_body": map[string]any{"type": "boolean", "description": "Return the full source of well-matching symbols."},
			},
			"required": []string{"name"},
		},
	},
	{
		Name:        "replace_symbol_body",
		Description: "Replace a whole symbol (function/class/method) by name path with new source, declaration line included, matching the file's indentation; doc comments above it are not part of the symbol. Applied to the editor buffer immediately and tracked; returns fresh diagnostics. Imports are organized, and the text lands as given unless format= asks for the server's formatter; the reply lists only new diagnostics. Do not use this on the user's selected region; that region is changed only via the <replacement> reply.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":      map[string]any{"type": "string", "description": "File containing the symbol."},
				"name_path": map[string]any{"type": "string", "description": "Symbol name path (full path if ambiguous)."},
				"line":      map[string]any{"type": "integer", "description": "The symbol's declaration line, when several answer to the same name path (find_symbol prints it)."},
				"files": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "Make the same edit in each of these files, in one call and one undo step. Alternative to file.",
				},
				"body":    map[string]any{"type": "string", "description": "Complete replacement source for the symbol."},
				"dry_run": map[string]any{"type": "boolean", "description": "Show a unified diff of the change without applying it."},
			},
			"required": []string{"file", "name_path", "body"},
		},
	},
	{
		Name:        "replace_symbol_lines",
		Description: "Replace part of a symbol: either the lines holding `match` (text that occurs once in the symbol - no line arithmetic, prefer this), or lines first_line..last_line, relative to the symbol's declaration (=1) as find_symbol bodies show, or absolute with absolute=true as read_file and grep report them. With match or absolute the doc comment above the symbol is reachable too. For a region with no symbol - a barrel/index file, an import block, an export list - omit name_path and give absolute=true line numbers or a match. Several places in one file go in chunks, each naming its own symbol (or none). Applied to the editor buffer immediately and tracked; returns fresh diagnostics and the text it replaced. Numbers relative to name_path are re-anchored on every call, so an edit above the symbol does not move them; absolute=true numbers are moved by any edit above them in the file, and both kinds are moved by an earlier edit inside the same symbol. Pass expect= with the current text of those lines whenever the numbers came from an earlier call: a stale offset is then caught instead of overwriting working code: when that text sits in exactly one other place the edit is applied there and the reply's `relocated` field says where (later numbers for the file are stale too - re-read or use match=); when it is nowhere or in several places the call is refused with what was found. Do not use this on the user's selected region; that region is changed only via the <replacement> reply.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":       map[string]any{"type": "string", "description": "File containing the symbol."},
				"name_path":  map[string]any{"type": "string", "description": "Symbol name path; the default for chunks that name none. A name two declarations share (Stack/push, Queue/push) is settled by the chunk's match text or absolute lines when only one of them holds it; otherwise give the full path."},
				"line":       map[string]any{"type": "integer", "description": "The symbol's declaration line, when several answer to the same name path (find_symbol prints it). A chunk takes its own line= for the symbol it names."},
				"files": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "Make the same edit in each of these files, in one call and one undo step. Alternative to file.",
				},
				"match":      map[string]any{"type": "string", "description": "The lines to replace, as they are now (whole lines); must occur exactly once in the symbol. Replaces first_line/last_line/expect."},
				"first_line": map[string]any{"type": "integer", "description": "First line to replace, relative to the symbol's declaration (1-based) unless absolute. Relative numbers are re-anchored to wherever the declaration is now, so an edit above the symbol does not move them."},
				"last_line":  map[string]any{"type": "integer", "description": "Last line to replace (inclusive)."},
				"absolute":   map[string]any{"type": "boolean", "description": "first_line/last_line are buffer line numbers (as read_file, grep and buffer_lines report them), not symbol-relative. These are not re-anchored: any edit above them in the file moves them, so pass expect= with numbers that came from an earlier call."},
				"text":       map[string]any{"type": "string", "description": "Replacement for those lines."},
				"expect": map[string]any{
					"type":        "string",
					"description": "The text those lines currently hold, or just the first of them. Pass it whenever the line numbers came from an earlier call: an earlier edit can have moved them, and without this the edit silently lands on the wrong lines. Text covering the whole range guards the whole range; shorter text anchors the start of it, the edit still replaces every line asked for, and the reply says how much was vouched for. Indentation is ignored when comparing, and a refusal names where the text sits now.",
				},
				"chunks": map[string]any{
					"type":        "array",
					"description": "Several non-overlapping replacements in the same file, instead of the single-edit fields. Each chunk may name its own symbol (name_path) and addresses its lines by match, or by first_line/last_line (relative to that symbol as it is now, or absolute). The call's name_path is the default for every chunk that names none, so a chunk for a region outside it (a const block, an import) needs its own name_path, or none with absolute=true; a match found once outside the scoping symbol is applied there and reported under relocated. Offsets and expect texts are checked together and the call is refused as a whole if any fails; what the new text means is checked afterwards by the language server, like any edit.",
					"items": map[string]any{
						"type": "object",
						"properties": map[string]any{
							"name_path":  map[string]any{"type": "string", "description": "Symbol this chunk edits (default: the call's name_path)."},
							"line":       map[string]any{"type": "integer", "description": "That symbol's declaration line, when several answer to the same name path."},
							"match":      map[string]any{"type": "string", "description": "Whole lines to replace, occurring once in the symbol; alternative to first_line/last_line."},
							"first_line": map[string]any{"type": "integer"},
							"last_line":  map[string]any{"type": "integer"},
							"absolute":   map[string]any{"type": "boolean"},
							"text":       map[string]any{"type": "string"},
							"expect":     map[string]any{"type": "string"},
						},
						"required": []string{"text"},
					},
				},
				"dry_run":          map[string]any{"type": "boolean", "description": "Show a unified diff of the change without applying it."},
				"full_diagnostics": map[string]any{"type": "boolean", "description": "List the pre-existing diagnostics again even when they have not changed since the last reply."},
			},
			"required": []string{"file"},
		},
	},
	{
		Name:        "insert_after_symbol",
		Description: "Insert source right after a symbol by name path (a blank line is added between multi-line symbols, and not between single-line ones such as the members of a const block). Applied to the editor buffer immediately and tracked.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":      map[string]any{"type": "string", "description": "File containing the anchor symbol."},
				"name_path": map[string]any{"type": "string", "description": "Anchor symbol name path."},
				"line":      map[string]any{"type": "integer", "description": "The anchor's declaration line, when several symbols answer to the same name path (find_symbol prints it)."},
				"files": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "Insert into each of these files, in one call and one undo step. Alternative to file.",
				},
				"text":    map[string]any{"type": "string", "description": "Source to insert."},
				"dry_run": map[string]any{"type": "boolean", "description": "Show a unified diff of the insertion without applying it."},
			},
			"required": []string{"file", "name_path", "text"},
		},
	},
	{
		Name: "run_tests",
		Description: "Run the project's tests from the root and answer with what failed, not a page of " +
			"output: each failure with its test name, file, line and the test symbol it sits in " +
			"(find_symbol reads it by name_path), the runner's pass/fail counts, and after the first " +
			"call in a root only which tests started or stopped failing since the last run. Without " +
			"arguments it uses the command remembered for this root, AGENT99_TEST, post_edit.test, or " +
			"a guess (a Makefile test target, go test, pytest, the package.json test script, cargo test, " +
			"busted). path= narrows to a directory or file and filter= to a test name where the runner " +
			"can (the guess is used for those). command= runs your own, and remember=true keeps it for " +
			"this root across sessions.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"path":     map[string]any{"type": "string", "description": "Directory or test file to limit the run to (relative to the root)."},
				"filter":   map[string]any{"type": "string", "description": "Test name (or pattern, in the runner's syntax) to run alone: go -run, pytest -k, jest -t, cargo's positional filter."},
				"command":  map[string]any{"type": "string", "description": "Test command to run instead of the default (cwd = root)."},
				"remember": map[string]any{"type": "boolean", "description": "Keep command= for later run_tests calls in this root, across sessions."},
				"reset":    map[string]any{"type": "boolean", "description": "Record a fresh baseline from this run instead of comparing."},
			},
			"required": []string{},
		},
	},
	{
		Name: "check_project",
		Description: "Run the project's whole-project check from the root. The first call in a " +
			"root records a baseline; later calls report only new and resolved lines. Use " +
			"after a refactor or before finishing. Without arguments it uses the configured " +
			"command, AGENT99_CHECK, or a guess (go build+vet, tsc --noEmit, cargo check, " +
			"pyright, qmllint) - all static checks, none of which run tests. When that is the wrong gate, " +
			"pass your own: commands=[...] runs several in turn (one per build configuration) " +
			"and reports every failure, and remember=true makes them the default for this root, kept across workspaces.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"command": map[string]any{"type": "string", "description": "Check command to run instead of the default."},
				"commands": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "Several commands, each run in turn; use for a project that needs checking under more than one build configuration.",
				},
				"remember": map[string]any{"type": "boolean", "description": "Keep this command for later check_project calls in this root, replacing the guess."},
				"reset":    map[string]any{"type": "boolean", "description": "Record a fresh baseline from this run."},
			},
			"required": []string{},
		},
	},
	{
		Name: "unreferenced_symbols",
		Description: "Top-level symbols in these files that nothing outside their own body mentions. " +
			"Run it after extracting code into a module or deleting a caller: a definition left " +
			"behind is not an error to any language server and not a warning to any linter, so " +
			"every edit reports clean and the dead copy ships. Uses the language server's " +
			"references where there is one, a whole-word project search where there is not. " +
			"A public API, a name reached by reflection or from a build configuration the search " +
			"cannot see lands here too: read each one before deleting it.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":  map[string]any{"type": "string", "description": "One file to check."},
				"files": map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "Several files to check."},
				"glob":  map[string]any{"type": "string", "description": "Path glob relative to root, e.g. src/**/*.go; subdirectories need a **/ prefix."},
				"include_tests": map[string]any{
					"type":        "boolean",
					"description": "Count references from test files as uses. Default false, so a symbol only its own test still calls is reported.",
				},
			},
			"required": []string{},
		},
	},
	{
		Name:        "rename_symbol",
		Description: "Rename the symbol at a position project-wide through the language server. dry_run lists affected files first. Undoable with undo_edit.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":     map[string]any{"type": "string", "description": "File containing the symbol."},
				"line":     map[string]any{"type": "integer", "description": "1-based line number."},
				"symbol":   map[string]any{"type": "string", "description": "Symbol text on that line, first occurrence. Prefer over col."},
				"col":      map[string]any{"type": "integer", "description": "1-based byte column, alternative to symbol."},
				"new_name": map[string]any{"type": "string", "description": "The new name."},
				"dry_run":  map[string]any{"type": "boolean", "description": "Only report what would change."},
			},
			"required": []string{"file", "line", "new_name"},
		},
	},
	{
		Name: "replace_pattern",
		Description: "The same textual change in many places, for the bulk edits a rename cannot " +
			"express: a call site's receiver changes (root.finiteNum -> Sanitize.finiteNum), an " +
			"argument is added, a constant is spelled differently. Use it instead of leaving for " +
			"a shell sed: the edits go through the buffers, the undo ledger and the diagnostics " +
			"report like any other edit. pattern is a Vim regex in very magic mode (close to an " +
			"extended regular expression; \\1..\\9 in the replacement are its groups), or plain " +
			"text with literal=true. It matches within one line. kind=code leaves matches inside " +
			"comments and string literals alone, which a regex cannot do on its own. dry_run " +
			"reports the counts and sample lines first.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"pattern":     map[string]any{"type": "string", "description": "Vim regex in very magic mode, or plain text with literal=true. Matches within one line. In very magic mode = makes the atom before it optional and < > are word boundaries, so a pattern quoting a line of code has to escape them (\\=, \\<) or pass literal=true; an alternation reports how many times each branch matched, and a branch that matched nothing is named."},
				"replacement": map[string]any{"type": "string", "description": "What each match becomes; \"\" deletes it. \\1..\\9 are the pattern's groups unless literal=true."},
				"literal":     map[string]any{"type": "boolean", "description": "Take both pattern and replacement as plain text, with nothing in them read as regex syntax."},
				"files": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "Files to work over (optional if glob is given).",
				},
				"glob": map[string]any{"type": "string", "description": "Path glob relative to root, e.g. src/**/*.go; subdirectories need a **/ prefix."},
				"kind": map[string]any{
					"type": "string",
					"enum": []string{"code", "comment", "string"},
					"description": "Replace only matches of this kind, classified by treesitter: code skips " +
						"comments and string literals, comment/string keep only those. Without it every match is replaced.",
				},
				"tests":   map[string]any{"type": "string", "enum": []string{"exclude", "only"}, "description": "exclude = production code only; only = test files only. Matched on the path, so it is exact."},
				"dry_run": map[string]any{"type": "boolean", "description": "Report what would change (per-file counts and sample lines) without applying it."},
			},
			"required": []string{"pattern", "replacement"},
		},
	},
	{
		Name:        "undo_edit",
		Description: "Undo the newest symbol edit(s) you made through this connection (count, or all), restoring the previous source, and removing a file it created. The ledger is per client: edits another agent made in the same workspace are in its own ledger and are never reached from here, and a reply says how many steps they have. Agents that share one MCP connection - the subagents of one session - count as one client and share this ledger. Refuses if the region changed since. A language server's own code action is not covered; an action offered by a refused edit is, since it re-runs that edit tool.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"count": map[string]any{"type": "integer", "description": "How many of the newest edits to undo (default 1)."},
				"all":   map[string]any{"type": "boolean", "description": "Undo every edit of yours this workspace still holds."},
				"skip":  map[string]any{"type": "boolean", "description": "Forget an entry that refuses to undo (its region changed since) and carry on with the older ones, instead of stopping there."},
			},
			"required": []string{},
		},
	},
	{
		Name:        "insert_before_symbol",
		Description: "Insert source right before a symbol by name path (import, helper, sibling declaration). Lands above the symbol's decorators, attributes and doc comment, not between them and the declaration. Applied to the editor buffer immediately and tracked.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":      map[string]any{"type": "string", "description": "File containing the anchor symbol."},
				"name_path": map[string]any{"type": "string", "description": "Anchor symbol name path."},
				"line":      map[string]any{"type": "integer", "description": "The anchor's declaration line, when several symbols answer to the same name path (find_symbol prints it)."},
				"files": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "Insert into each of these files, in one call and one undo step. Alternative to file.",
				},
				"text":    map[string]any{"type": "string", "description": "Source to insert."},
				"dry_run": map[string]any{"type": "boolean", "description": "Show a unified diff of the insertion without applying it."},
			},
			"required": []string{"file", "name_path", "text"},
		},
	},
	{
		Name:        "insert_lines",
		Description: "Insert source at a line, where there is no symbol to anchor it to: the top of a file whose first statement is a bare call, the end of a list. line=N puts the text above line N (1-based, as read_file and grep report lines); at=start/end is the same without having to know the file's length. files= takes the same text to several files in one call, so one guard reaches a directory of them. Applied and saved to disk immediately.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file": map[string]any{"type": "string", "description": "File to insert into (absolute or relative to root)."},
				"files": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "Several files to insert the same text into, each at the same place.",
				},
				"line": map[string]any{"type": "integer", "description": "1-based buffer line; the text lands above it, so line=1 prepends. One past the last line appends. Alternative to at."},
				"at": map[string]any{
					"type":        "string",
					"enum":        []string{"start", "end"},
					"description": "Insert at the top or the bottom of each file, whatever its length. Alternative to line.",
				},
				"text":    map[string]any{"type": "string", "description": "Source to insert. It lands as given; no blank line is added around it."},
				"dry_run": map[string]any{"type": "boolean", "description": "Show a unified diff of the insertion without applying it."},
			},
			"required": []string{"text"},
		},
	},
	{
		Name:        "document_symbols",
		Description: "Outline of one file from the language server.",
		InputSchema: fileOnlySchema(),
	},
	{
		Name:        "workspace_symbols",
		Description: "Fuzzy-search symbol names across the project; use when the file is unknown.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"query": map[string]any{"type": "string", "description": "Symbol name or fragment."},
			},
			"required": []string{"query"},
		},
	},
	{
		Name:        "diagnostics",
		Description: "Errors/warnings/hints for a file. Entries with quick_fixes are fixable via code_actions + apply_code_action.",
		InputSchema: fileOnlySchema(),
	},
	{
		Name:        "buffer_lines",
		Description: "Read a file as the editor sees it, including unsaved changes. Use buffer_lines instead for files the user has open in the editor (they may have unsaved changes).",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":  map[string]any{"type": "string", "description": "File path (absolute or relative to root)."},
				"first": map[string]any{"type": "integer", "description": "Optional 1-based first line (default 1)."},
				"last":  map[string]any{"type": "integer", "description": "Optional 1-based last line (default: end of buffer)."},
			},
			"required": []string{"file"},
		},
	},
	{
		Name: "create_file",
		Description: "Create a new file with its contents, with imports organized (and formatted when format= asks for it), " +
			"and tell the language servers about it. Missing parent directories are created. Undoable with undo_edit.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file": map[string]any{"type": "string", "description": "Path of the new file (absolute or relative to root)."},
				"text": map[string]any{"type": "string", "description": "Contents of the new file."},
			},
			"required": []string{"file", "text"},
		},
	},
	{
		Name: "move_file",
		Description: "Move or rename a file through the language servers, so they rewrite the imports and " +
			"references that name the old path. Always prefer this over a shell mv. Undoable with undo_edit.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"from": map[string]any{"type": "string", "description": "Current path (absolute or relative to root)."},
				"to":   map[string]any{"type": "string", "description": "New path (absolute or relative to root); its directory is created if missing."},
			},
			"required": []string{"from", "to"},
		},
	},
	{
		Name: "move_symbols",
		Description: "Move whole symbols (functions, classes, constants) from one file to another, taking each one's doc comment with it and sorting and pruning the imports of both files afterwards. Adding an import the moved code now needs is something only some servers do on that pass (gopls does; pyright, tsserver and lua_ls do not), so read the reply's verdict for unresolved names before treating the move as finished. " +
			"The way to split an oversized file: the destination is created if missing. Undoable with undo_edit.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"from": map[string]any{"type": "string", "description": "File the symbols are in now."},
				"to":   map[string]any{"type": "string", "description": "File to move them into; created if it does not exist."},
				"names": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "Name paths of the symbols to move, as find_symbol reports them.",
				},
				"header": map[string]any{"type": "string", "description": "Text to start a newly created destination with. Defaults to the source's `package X` line when there is one; supply it for languages where that is not enough."},
			},
			"required": []string{"from", "to", "names"},
		},
	},
	{
		Name: "delete_file",
		Description: "Delete one file, letting the language servers react and reporting what broke elsewhere. " +
			"Undoable with undo_edit, which restores the contents.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file": map[string]any{"type": "string", "description": "File to delete (absolute or relative to root)."},
			},
			"required": []string{"file"},
		},
	},
}

// fileTools run in this process; only the "agent" subcommand exposes them
// (the claude provider has its own Read/Grep/Glob).
var fileTools = []tool{
	{
		Name:        "read_file",
		Description: fmt.Sprintf("Read a file with line numbers (offset/limit). A plain read of a "+
			"file over %d lines returns its skim (the outline) instead of its text; pass "+
			"offset/limit to read the text of one anyway.", autoSkimThreshold),
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"path":   map[string]any{"type": "string", "description": "File path (absolute or relative to root)."},
				"offset": map[string]any{"type": "integer", "description": fmt.Sprintf("1-based first line to read (default 1). Passing it also asks for the text rather than the skim, whatever the file's length; a plain read over %d lines is answered with the outline.", autoSkimThreshold)},
				"limit":  map[string]any{"type": "integer", "description": fmt.Sprintf("Maximum number of lines (default %d).", maxReadLines)},
			},
			"required": []string{"path"},
		},
	},
	{
		Name:        "grep",
		Description: "Regex search (ripgrep syntax) with context. Hits carry a tag: path:line [Symbol kind @pos/len dN !SEV ~age · signature · doc]: kind is def/call/comment/string, dN nesting depth, !ERROR an existing diagnostic, test: a test file, ~age needs blame=true. Usually no follow-up read is needed. Narrow with kind= (code skips comments and strings) and tests=, rather than by grepping again with a cleverer pattern.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"pattern": map[string]any{"type": "string", "description": "Regular expression to search for."},
				"path":    map[string]any{"type": "string", "description": "Subdirectory or file (default: root)."},
				"glob":    map[string]any{"type": "string", "description": "Path glob relative to the root, e.g. src/**/*.go; subdirectories need a **/ prefix."},
				"kind": map[string]any{
					"type":        "string",
					"enum":        []string{"def", "call", "comment", "string", "code"},
					"description": "Keep only hits of this kind: code = anything that is not a comment or a string, which drops prose mentions of an identifier. Implies no context lines.",
				},
				"tests": map[string]any{
					"type":        "string",
					"enum":        []string{"exclude", "only"},
					"description": "exclude = production code only; only = test files only. Matched on the path, so it is exact.",
				},
				"context": map[string]any{"type": "integer", "description": "Context lines around each match (default 2, max 10)."},
				"blame":   map[string]any{"type": "boolean", "description": "Add git blame age per hit (slower)."},
				"files": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "Search only these files, instead of walking path=.",
				},
				"text": map[string]any{"type": "boolean", "description": "Search files holding a NUL byte in full. Without it the searcher stops at the first match in such a file - a source file with one stray NUL is searched no further - and the reply names the files it gave up on."},
			},
			"required": []string{"pattern"},
		},
	},
	{
		Name: "list_files",
		Description: "List project file paths (respects .gitignore); images and other binaries are left out. " +
			"Prefer workspace_map, which lists the same files with their declarations.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"path": map[string]any{"type": "string", "description": "Subdirectory (default: root)."},
				"glob": map[string]any{"type": "string", "description": "Path glob, e.g. src/**/*.go or *.go."},
			},
			"required": []string{},
		},
	},
}

// debugTools drive a Debug Adapter Protocol session through nvim-dap inside
// the same Neovim. They are advertised only with AGENT99_DEBUG=1 (see
// debugEnabled): thirteen schemas cost prompt tokens on every round for a
// model that is not debugging.
var debugTools = []tool{
	{
		Name: "debug_launch",
		Description: "Start the program under a debugger and wait for the first stop or its exit. file picks the adapter by " +
			"filetype (Go: its package, or the package's tests when file is a _test.go, with args like -test.run NAME; Python/JS/TS: the script; Java: the file with main; C/C++/Rust: pass program, the binary). No arguments relaunches " +
			"the previous configuration with breakpoints kept. Replies with the stop context: frame, source, locals, stack, output.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":          map[string]any{"type": "string", "description": "Source file to run (its filetype picks the adapter)."},
				"program":       map[string]any{"type": "string", "description": "Program to run: a Go package directory, a Python script, or a built binary."},
				"args":          map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "Command-line arguments."},
				"cwd":           map[string]any{"type": "string", "description": "Working directory (default: root)."},
				"env":           map[string]any{"type": "object", "additionalProperties": map[string]any{"type": "string"}, "description": "Extra environment variables."},
				"config":        map[string]any{"type": "string", "description": "Name of a user nvim-dap configuration to run instead of a built-in adapter."},
				"adapter":       map[string]any{"type": "string", "enum": []string{"delve", "debugpy", "codelldb", "lldb-dap", "gdb", "js-debug", "java"}, "description": "Force a built-in adapter."},
				"stop_on_entry": map[string]any{"type": "boolean", "description": "Stop at the first line (default false: run to the first breakpoint or exit)."},
				"variables":     map[string]any{"type": "string", "enum": []string{"summary", "names", "none"}, "description": "How much of the locals every stop reply carries (default summary)."},
				"track":         map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "Expressions evaluated in the top frame at every stop."},
				"again":         map[string]any{"type": "boolean", "description": "Relaunch the previous configuration."},
				"wait_ms":       map[string]any{"type": "integer", "description": "How long to wait for the first stop (default 30000, max 240000)."},
			},
		},
	},
	{
		Name: "debug_attach",
		Description: "Attach to a running process (pid) or a debug server (host, port) and wait for the first stop. " +
			"On Linux with ptrace_scope=1 attaching by pid fails; start the target under dlv exec --headless or python -m debugpy --listen and use host/port.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"pid":       map[string]any{"type": "integer", "description": "Process id to attach to."},
				"host":      map[string]any{"type": "string", "description": "Debug server host (default 127.0.0.1)."},
				"port":      map[string]any{"type": "integer", "description": "Debug server port."},
				"adapter":   map[string]any{"type": "string", "enum": []string{"delve", "debugpy", "codelldb", "lldb-dap", "gdb", "js-debug", "java"}, "description": "Adapter to use; else picked from file's filetype."},
				"file":      map[string]any{"type": "string", "description": "A source file of the target, to pick the adapter by filetype."},
				"config":    map[string]any{"type": "string", "description": "Name of a user nvim-dap attach configuration."},
				"variables": map[string]any{"type": "string", "enum": []string{"summary", "names", "none"}},
				"track":     map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
				"wait_ms":   map[string]any{"type": "integer"},
			},
		},
	},
	{
		Name: "debug_breakpoint",
		Description: "Set (or remove) a breakpoint at file:line, or at a symbol by name path plus a 1-based offset from its declaration " +
			"as find_symbol numbers it. Works before a session exists (sent at launch). The reply says where the adapter actually put it.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":          map[string]any{"type": "string", "description": "File path (absolute or relative to root)."},
				"line":          map[string]any{"type": "integer", "description": "1-based line."},
				"name_path":     map[string]any{"type": "string", "description": "Symbol name path, alternative to line."},
				"offset":        map[string]any{"type": "integer", "description": "1-based line offset from the symbol's declaration (default 1)."},
				"condition":     map[string]any{"type": "string", "description": "Break only when this expression is true."},
				"hit_condition": map[string]any{"type": "string", "description": "Break on the Nth hit, adapter syntax."},
				"log_message":   map[string]any{"type": "string", "description": "Log this instead of stopping (logpoint)."},
				"remove":        map[string]any{"type": "boolean", "description": "Remove the breakpoint at that line instead."},
			},
			"required": []string{"file"},
		},
	},
	{
		Name:        "debug_breakpoints",
		Description: "List the agent's breakpoints with their verified state, or clear them all.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"clear": map[string]any{"type": "boolean", "description": "Remove every breakpoint this server placed."},
			},
		},
	},
	{
		Name:        "debug_continue",
		Description: "Resume and wait for the next stop or exit. to = run to a line (file plus line or name_path/offset) via a temporary breakpoint.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"wait_ms": map[string]any{"type": "integer", "description": "How long to wait (default 30000, max 240000)."},
				"to": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"file":      map[string]any{"type": "string"},
						"line":      map[string]any{"type": "integer"},
						"name_path": map[string]any{"type": "string"},
						"offset":    map[string]any{"type": "integer"},
					},
					"required": []string{"file"},
				},
			},
		},
	},
	{
		Name:        "debug_step",
		Description: "Step over, into or out, count times, and reply with the last stop. More than three steps in a row usually means a breakpoint would serve better.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"action":  map[string]any{"type": "string", "enum": []string{"over", "into", "out"}, "description": "Default over."},
				"count":   map[string]any{"type": "integer", "description": "Repeat count (default 1)."},
				"wait_ms": map[string]any{"type": "integer"},
			},
		},
	},
	{
		Name:        "debug_wait",
		Description: "Wait for a running session to stop; wait_ms=0 reports the current state without waiting. pause_after interrupts the program when the wait expires.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"wait_ms":     map[string]any{"type": "integer", "description": "Default 30000, max 240000; 0 = just report."},
				"pause_after": map[string]any{"type": "boolean", "description": "Send pause if nothing stopped in time."},
			},
		},
	},
	{
		Name:        "debug_stack",
		Description: "Stack of the stopped thread, one line per frame; frames outside the workspace collapse into <external ×N> unless all_frames.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"depth":      map[string]any{"type": "integer", "description": "Frames to fetch (default 12)."},
				"thread":     map[string]any{"type": "integer", "description": "Thread id (default: the stopped one)."},
				"all_frames": map[string]any{"type": "boolean", "description": "Show frames outside the workspace too."},
			},
		},
	},
	{
		Name:        "debug_variables",
		Description: "Locals and arguments of a frame as `name: type = value` lines (clipped), one level deep; expand drills into one path by expression.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"frame":  map[string]any{"type": "integer", "description": "Frame index (default 0)."},
				"scope":  map[string]any{"type": "string", "enum": []string{"locals", "globals", "all"}, "description": "Default locals."},
				"expand": map[string]any{"type": "string", "description": "Expression whose children to list, e.g. req.Header."},
				"depth":  map[string]any{"type": "integer", "description": "Nesting depth (default 1, max 3)."},
				"max":    map[string]any{"type": "integer", "description": "Maximum entries (default 40)."},
			},
		},
	},
	{
		Name:        "debug_evaluate",
		Description: "Evaluate an expression in a frame of the stopped thread. Calls that mutate state are your responsibility.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"expression": map[string]any{"type": "string"},
				"frame":      map[string]any{"type": "integer", "description": "Frame index (default 0)."},
				"context":    map[string]any{"type": "string", "enum": []string{"repl", "watch", "hover"}, "description": "Default repl."},
			},
			"required": []string{"expression"},
		},
	},
	{
		Name:        "debug_output",
		Description: "Program and adapter output captured so far (up to 200 lines); survives the session's exit until the next launch.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"tail": map[string]any{"type": "integer", "description": "Last N lines (default 100, max 200)."},
				"grep": map[string]any{"type": "string", "description": "Keep only lines matching this Vim regex."},
			},
		},
	},
	{
		Name:        "debug_stop",
		Description: "End the session: terminate a launched program, or disconnect from an attached one leaving it running (force terminates it too). Removes the agent's breakpoints.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"force": map[string]any{"type": "boolean", "description": "Terminate an attached process as well."},
			},
		},
	},
	{
		Name:        "install_debugger",
		Description: "Install the debug adapter for a language through Mason (delve, debugpy, codelldb). Slow; once per language.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"language": map[string]any{"type": "string", "description": "Filetype (go, python, c, cpp, rust) or a file extension."},
				"package":  map[string]any{"type": "string", "description": "Mason package to install instead of the default for the language."},
			},
			"required": []string{"language"},
		},
	},
}

// debugEnabled reports whether the debugger tools are served. The plugin
// sets AGENT99_DEBUG for the bridges it spawns when debug.enabled is on;
// the standalone server takes it from its own environment.
func debugEnabled() bool {
	return os.Getenv("AGENT99_DEBUG") != ""
}

var debugToolNames = func() map[string]bool {
	set := map[string]bool{}
	for _, t := range debugTools {
		set[t.Name] = true
	}
	return set
}()

// The edit tools that write text a caller composed, as opposed to moving
// or undoing what is already there. Only these can mangle an escape on the
// way in, so only these take verify.
var writingTools = map[string]bool{
	"replace_symbol_body":  true,
	"replace_symbol_lines": true,
	"insert_after_symbol":  true,
	"insert_before_symbol": true,
	"insert_lines":         true,
}

// The edit tools that run the server's formatter over what they wrote when
// asked to. Formatting is off unless setup(), AGENT99_FORMAT or the call
// itself turns it on, so each of these takes a format switch.
var formattingTools = map[string]bool{
	"replace_symbol_body":  true,
	"replace_symbol_lines": true,
	"insert_after_symbol":  true,
	"insert_before_symbol": true,
	"insert_lines":         true,
	"create_file":          true,
	"move_symbols":         true,
}

// Every edit tool reports diagnostics the same way, and every tool that
// writes new text can echo the bytes it wrote, so both switches are added
// to their schemas here rather than repeated in each one.
func init() {
	for i := range lspTools {
		props, ok := lspTools[i].InputSchema["properties"].(map[string]any)
		if !ok {
			continue
		}
		if editTools[lspTools[i].Name] {
			if _, has := props["full_diagnostics"]; !has {
				props["full_diagnostics"] = map[string]any{
					"type":        "boolean",
					"description": "List the pre-existing diagnostics again even when they have not changed since the last reply.",
				}
			}
		}
		if writingTools[lspTools[i].Name] {
			props["verify"] = map[string]any{
				"type": "boolean",
				"description": "Echo the bytes that landed, as the file now holds them. Use when the text " +
					"carries escapes or whitespace that must survive the JSON round trip exactly.",
			}
		}
		if formattingTools[lspTools[i].Name] {
			props["wait"] = map[string]any{
				"type": "boolean",
				"description": "Default true: the reply carries the language server's verdict on the edit. " +
					"false: return as soon as the text is in; the verdict comes with the next reply, " +
					"whatever tool produces it, under deferred_verdicts. Use it for a run of edits " +
					"you will check together.",
			}
			props["format"] = map[string]any{
				"type": "string",
				"enum": []string{"off", "range", "file"},
				"description": "Run the language server's formatter over the written text afterwards. " +
					"Default off: the text lands byte for byte as given. \"range\" formats the " +
					"edited lines (servers with no range formatting, such as gopls, format the " +
					"file and only the edited lines are kept); \"file\" formats the whole file. " +
					"Either way the pass is confined to the edited lines, and it is taken back " +
					"(and the reason reported in format_skipped) when it changes the text inside " +
					"a string literal or re-indents to a width the file does not use.",
			}
		}
	}
}
