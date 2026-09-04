package main

// Tool definitions and execution. The LSP tools run inside Neovim (see
// nvim.go and the plugin's lua/agent99/lsp.lua); the file tools run here,
// rooted at the project.

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	maxToolOutputChars = 30000
	maxGrepLines       = 200
	maxListFiles       = 500
	maxReadLines       = 2000
)

type tool struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

// Tools in this set are still executable but are left out of the default
// ("slim") schema advertised to the model: measured usage is near zero and
// skim/find_symbol cover them, while every advertised schema costs prompt
// tokens on every round. Restore them with provider.full_tools = true
// (agent) or AGENT99_FULL_TOOLS=1 (MCP server).
var extraTools = map[string]bool{
	"install_language": true, // standalone MCP advertises it regardless
	"type_definition":  true,
	"implementation":   true,
	"incoming_calls":   true,
	"outgoing_calls":   true,
	"document_symbols": true,
	"expand_symbol":    true,
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
		Name:        "workspace_map",
		Description: "Every project file with its line count and declarations - classes with their methods one level in - in one cheap call. The first move in an unfamiliar repo. Test files are left out unless include_tests.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"path": map[string]any{"type": "string", "description": "Subdirectory (default: root)."},
				"glob": map[string]any{"type": "string", "description": "Path glob relative to the root, e.g. src/**/*.go; subdirectories need a **/ prefix."},
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
		Description: "Find symbols by name or name path (\"Class/method\"; suffix and substring match) in files/glob, optionally with full source (include_body) numbered relative to the symbol, ready for replace_symbol_lines. Cheapest way to read one function.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"name":         map[string]any{"type": "string", "description": "Name or name path; suffix/substring match."},
				"file":         map[string]any{"type": "string", "description": "One file to search."},
				"files":        map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "Several files to search."},
				"glob":         map[string]any{"type": "string", "description": "Path glob relative to root, e.g. **/*.go; subdirectories need a **/ prefix."},
				"include_body": map[string]any{"type": "boolean", "description": "Return the full source of well-matching symbols."},
			},
			"required": []string{"name"},
		},
	},
	{
		Name:        "replace_symbol_body",
		Description: "Replace a whole symbol (function/class/method) by name path with new source, declaration line included, matching the file's indentation; doc comments above it are not part of the symbol. Applied to the editor buffer immediately and tracked; returns fresh diagnostics. The region is formatted and imports organized; the reply lists only new diagnostics. Do not use this on the user's selected region; that region is changed only via the <replacement> reply.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":      map[string]any{"type": "string", "description": "File containing the symbol."},
				"name_path": map[string]any{"type": "string", "description": "Symbol name path (full path if ambiguous)."},
				"body":      map[string]any{"type": "string", "description": "Complete replacement source for the symbol."},
			},
			"required": []string{"file", "name_path", "body"},
		},
	},
	{
		Name:        "replace_symbol_lines",
		Description: "Replace lines first_line..last_line of a symbol, numbered relative to its declaration (=1) as find_symbol bodies show; prefer over replace_symbol_body for small changes. Applied to the editor buffer immediately and tracked; returns fresh diagnostics. Do not use this on the user's selected region; that region is changed only via the <replacement> reply.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":       map[string]any{"type": "string", "description": "File containing the symbol."},
				"name_path":  map[string]any{"type": "string", "description": "Symbol name path."},
				"first_line": map[string]any{"type": "integer", "description": "First line to replace, relative to the symbol (1-based)."},
				"last_line":  map[string]any{"type": "integer", "description": "Last line to replace, relative to the symbol (inclusive)."},
				"text":       map[string]any{"type": "string", "description": "Replacement for those lines."},
			},
			"required": []string{"file", "name_path", "first_line", "last_line", "text"},
		},
	},
	{
		Name:        "insert_after_symbol",
		Description: "Insert source right after a symbol by name path (a blank line is added). Applied to the editor buffer immediately and tracked.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":      map[string]any{"type": "string", "description": "File containing the anchor symbol."},
				"name_path": map[string]any{"type": "string", "description": "Anchor symbol name path."},
				"text":      map[string]any{"type": "string", "description": "Source to insert."},
			},
			"required": []string{"file", "name_path", "text"},
		},
	},
	{
		Name: "check_project",
		Description: "Run the project's whole-project check from the root. The first call in a " +
			"root records a baseline; later calls report only new and resolved lines. Use " +
			"after a refactor or before finishing. Without arguments it uses the configured " +
			"command, AGENT99_CHECK, or a guess (go build+vet, tsc --noEmit, cargo check, " +
			"pyright) - all type checks, none of which run tests. When that is the wrong gate, " +
			"pass your own: commands=[...] runs several in turn (one per build configuration) " +
			"and reports every failure, and remember=true makes them the default for this root.",
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
		Name:        "undo_edit",
		Description: "Undo the newest symbol edit(s) of this run (count, or all), restoring the previous source. Refuses if the region changed since. Code actions are not covered.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"count": map[string]any{"type": "integer", "description": "How many of the newest edits to undo (default 1)."},
				"all":   map[string]any{"type": "boolean", "description": "Undo every edit of this run."},
			},
			"required": []string{},
		},
	},
	{
		Name:        "insert_before_symbol",
		Description: "Insert source right before a symbol by name path (import, helper, decorator). Applied to the editor buffer immediately and tracked.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":      map[string]any{"type": "string", "description": "File containing the anchor symbol."},
				"name_path": map[string]any{"type": "string", "description": "Anchor symbol name path."},
				"text":      map[string]any{"type": "string", "description": "Source to insert."},
			},
			"required": []string{"file", "name_path", "text"},
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
		Description: "Create a new file with its contents, formatted and with imports organized, " +
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
		Description: "Read a file with line numbers (offset/limit). A large file returns its skim instead.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"path":   map[string]any{"type": "string", "description": "File path (absolute or relative to root)."},
				"offset": map[string]any{"type": "integer", "description": "1-based first line to read (default 1)."},
				"limit":  map[string]any{"type": "integer", "description": fmt.Sprintf("Maximum number of lines (default %d).", maxReadLines)},
			},
			"required": []string{"path"},
		},
	},
	{
		Name:        "grep",
		Description: "Regex search (ripgrep syntax) with context. Hits carry a tag: path:line [Symbol kind @pos/len dN !SEV ~age · signature · doc]: kind is def/call/comment/string, dN nesting depth, !ERROR an existing diagnostic, test: a test file, ~age needs blame=true. Usually no follow-up read is needed.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"pattern": map[string]any{"type": "string", "description": "Regular expression to search for."},
				"path":    map[string]any{"type": "string", "description": "Subdirectory or file (default: root)."},
				"glob":    map[string]any{"type": "string", "description": "Path glob relative to the root, e.g. src/**/*.go; subdirectories need a **/ prefix."},
				"context": map[string]any{"type": "integer", "description": "Context lines around each match (default 2, max 10)."},
				"blame":   map[string]any{"type": "boolean", "description": "Add git blame age per hit (slower)."},
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

var lspToolNames = func() map[string]bool {
	set := map[string]bool{}
	for _, t := range lspTools {
		set[t.Name] = true
	}
	return set
}()

func resolveInRoot(root string, path any) string {
	s, _ := path.(string)
	if s == "" {
		return root
	}
	if !filepath.IsAbs(s) {
		s = filepath.Join(root, s)
	}
	return filepath.Clean(s)
}

func argInt(args map[string]any, key string, def int) int {
	if v, ok := args[key]; ok {
		if f, ok := v.(float64); ok {
			return int(f)
		}
	}
	return def
}

// Above this size, a plain read (no offset/limit) returns the file's skim
// instead of its content: the structure is almost always what the model
// actually needs, at a fraction of the tokens.
const autoSkimThreshold = 400

func countLines(path string) int {
	f, err := os.Open(path)
	if err != nil {
		return 0
	}
	defer f.Close()
	n := 0
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		n++
	}
	return n
}

// Breadcrumb for a partial read: which symbol the region starts inside.
func readContext(file string, line int) string {
	if os.Getenv("AGENT99_NO_LSP") != "" || line <= 1 {
		return ""
	}
	res, err := nvimCall("enclosing_symbols",
		map[string]any{"file": file, "lines": []any{line}})
	if err != nil {
		return ""
	}
	symbols, _ := res.(map[string]any)["symbols"].(map[string]any)
	info, _ := symbols[fmt.Sprintf("%d", line)].(map[string]any)
	if info == nil {
		return ""
	}
	path, _ := info["path"].(string)
	if path == "" {
		return ""
	}
	if decl, _ := info["decl"].(string); decl != "" {
		return fmt.Sprintf("context: this region starts inside %s - %s", path, decl)
	}
	return "context: this region starts inside " + path
}

func runReadFile(root string, args map[string]any) (string, error) {
	path := resolveInRoot(root, args["path"])
	explicit := args["offset"] != nil || args["limit"] != nil
	if !explicit && os.Getenv("AGENT99_NO_LSP") == "" {
		if n := countLines(path); n > autoSkimThreshold {
			if res, err := nvimCall("skim", map[string]any{"files": []any{path}}); err == nil {
				pretty, merr := renderJSON(res)
				if merr == nil {
					return fmt.Sprintf(
						"%s has %d lines - returning its structure instead of the full "+
							"content. Read a specific region with offset/limit, or fetch one "+
							"symbol with find_symbol include_body=true.\n%s",
						path, n, pretty), nil
				}
			}
		}
	}
	offset := argInt(args, "offset", 1)
	if offset < 1 {
		offset = 1
	}
	limit := argInt(args, "limit", maxReadLines)
	if limit > maxReadLines {
		limit = maxReadLines
	}
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	var out []string
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for i := 1; scanner.Scan(); i++ {
		if i < offset {
			continue
		}
		if i >= offset+limit {
			out = append(out, fmt.Sprintf("... (truncated at %d lines)", limit))
			break
		}
		out = append(out, fmt.Sprintf("%d: %s", i, scanner.Text()))
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	if len(out) == 0 {
		return "(empty range)", nil
	}
	if explicit {
		if crumb := readContext(path, offset); crumb != "" {
			out = append([]string{crumb}, out...)
		}
	}
	return strings.Join(out, "\n"), nil
}

func runGrep(root string, args map[string]any) (string, error) {
	pattern, _ := args["pattern"].(string)
	if pattern == "" {
		return "", errors.New("missing required argument: pattern")
	}
	target := resolveInRoot(root, args["path"])
	ctx := argInt(args, "context", 2)
	if ctx < 0 {
		ctx = 0
	}
	if ctx > 10 {
		ctx = 10
	}
	ctxArg := fmt.Sprintf("-C%d", ctx)
	glob, _ := args["glob"].(string)
	blame, _ := args["blame"].(bool)
	// Both searchers match a glob against the path as they walk it, so a
	// root-relative glob like "src/**/*.go" only works if the path they
	// walk is root-relative too. Search from the root with a relative
	// target and put the root back on the results afterwards, so that a
	// glob here means the same thing it means in find_symbol and skim.
	searchDir, searchTarget := root, "."
	if rel, err := filepath.Rel(root, target); err == nil && !strings.HasPrefix(rel, "..") {
		searchTarget = rel
	} else {
		searchDir, searchTarget = "", target
	}
	var cmd *exec.Cmd
	if _, err := exec.LookPath("rg"); err == nil {
		// --sort path costs rg its parallelism but makes the output
		// deterministic; without it two identical greps are not
		// byte-identical, which defeats the duplicate-result guard.
		// -H keeps the filename even for a single-file target, which the
		// annotator's path:line:col parsing depends on.
		cargs := []string{"-H", "-n", "--column", "--no-heading", "-S", "--sort", "path", ctxArg}
		if glob != "" {
			cargs = append(cargs, "-g", glob)
		}
		cargs = append(cargs, "-e", pattern, searchTarget)
		cmd = exec.Command("rg", cargs...)
	} else {
		cargs := []string{"-rnHIE", ctxArg}
		if glob != "" {
			cargs = append(cargs, "--include="+glob)
		}
		cargs = append(cargs, "-e", pattern, searchTarget)
		cmd = exec.Command("grep", cargs...)
	}
	cmd.Dir = searchDir
	out, err := cmd.Output()
	if err != nil {
		// Exit code 1 just means "no matches" for both rg and grep.
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 1 {
			return "(no matches)", nil
		}
		return "", fmt.Errorf("grep failed: %v", err)
	}
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	if len(lines) > maxGrepLines {
		lines = append(lines[:maxGrepLines],
			fmt.Sprintf("... (truncated at %d matches)", maxGrepLines))
	}
	if searchDir != "" {
		absolutizeGrepPaths(lines, searchDir)
	}
	annotateGrepHits(lines, blame)
	return strings.Join(lines, "\n"), nil
}

// Put the search root back in front of the paths the searcher printed. It
// ran with the root as its working directory (so that globs are
// root-relative), which makes every hit relative; the annotator and the
// agent both want a path they can open from anywhere.
func absolutizeGrepPaths(lines []string, root string) {
	for i, l := range lines {
		if l == "" || l == "--" || strings.HasPrefix(l, "/") {
			continue
		}
		// Plain concatenation, not filepath.Join: the rest of the line is
		// matched source text, and cleaning it would rewrite any "//" or
		// "/./" the code happens to contain.
		lines[i] = strings.TrimSuffix(root, "/") + "/" + strings.TrimPrefix(l, "./")
	}
}

var testPathRe = regexp.MustCompile(`(^|/)(tests?|spec)(/|$)|_test\.|_spec\.|\.test\.|\.spec\.`)

// Age of each requested line's last change, humanized ("today", "5d", "3mo",
// "2y"), via one git blame call per file.
func blameAges(file string, lineNos []int) map[int]string {
	cargs := []string{"-C", filepath.Dir(file), "blame", "--line-porcelain"}
	for _, n := range lineNos {
		cargs = append(cargs, "-L", fmt.Sprintf("%d,%d", n, n))
	}
	cargs = append(cargs, "--", file)
	// Partial clones (e.g. lazy.nvim's blob:none) make blame fetch missing
	// blobs from the network, which can hang indefinitely: forbid lazy
	// fetching and cap the whole call.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", cargs...)
	cmd.Env = append(os.Environ(), "GIT_NO_LAZY_FETCH=1")
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	ages := map[int]string{}
	current := 0
	headerRe := regexp.MustCompile(`^[0-9a-f]{40} \d+ (\d+)`)
	for _, l := range strings.Split(string(out), "\n") {
		if m := headerRe.FindStringSubmatch(l); m != nil {
			fmt.Sscanf(m[1], "%d", &current)
			continue
		}
		if ts, ok := strings.CutPrefix(l, "author-time "); ok && current > 0 {
			var epoch int64
			fmt.Sscanf(ts, "%d", &epoch)
			days := int(time.Since(time.Unix(epoch, 0)).Hours() / 24)
			switch {
			case days < 1:
				ages[current] = "today"
			case days < 60:
				ages[current] = fmt.Sprintf("%dd", days)
			case days < 730:
				ages[current] = fmt.Sprintf("%dmo", days/30)
			default:
				ages[current] = fmt.Sprintf("%dy", days/365)
			}
		}
	}
	return ages
}

// Rewrite "path:NN:text" grep hits with their enclosing symbol, by asking
// Neovim for the symbol containing each hit. The first hit inside a symbol
// also carries the symbol's signature (its declaration line) and doc-comment
// summary, so most hits need no follow-up read at all. Best-effort: any
// failure (no editor, no parser) leaves the plain hits untouched.
func annotateGrepHits(lines []string, blame bool) {
	if os.Getenv("AGENT99_NO_LSP") != "" {
		return
	}
	type hit struct {
		idx  int
		line int
		col  int
		rest string
	}
	byFile := map[string][]hit{}
	var order []string
	for i, l := range lines {
		p1 := strings.Index(l, ":")
		if p1 <= 0 {
			continue
		}
		p2 := strings.Index(l[p1+1:], ":")
		if p2 <= 0 {
			continue
		}
		lineNo := 0
		if _, err := fmt.Sscanf(l[p1+1:p1+1+p2], "%d", &lineNo); err != nil || lineNo <= 0 {
			continue
		}
		rest := l[p1+1+p2+1:]
		// rg --column emits path:line:col:text; take the column if present.
		col := 0
		if p3 := strings.Index(rest, ":"); p3 > 0 {
			if _, err := fmt.Sscanf(rest[:p3], "%d", &col); err == nil && col > 0 {
				rest = rest[p3+1:]
			} else {
				col = 0
			}
		}
		file := l[:p1]
		if len(byFile[file]) == 0 {
			order = append(order, file)
		}
		byFile[file] = append(byFile[file], hit{idx: i, line: lineNo, col: col, rest: rest})
	}
	annotated := 0
	seenSymbol := map[string]bool{}
	for fi, file := range order {
		if fi >= 8 || annotated >= 60 {
			return
		}
		var want, cols []any
		var lineNos []int
		for _, h := range byFile[file] {
			want = append(want, h.line)
			cols = append(cols, h.col)
			lineNos = append(lineNos, h.line)
		}
		res, err := nvimCall("enclosing_symbols",
			map[string]any{"file": file, "lines": want, "cols": cols})
		if err != nil {
			return // editor unreachable; leave the rest plain too
		}
		var ages map[int]string
		if blame {
			ages = blameAges(file, lineNos)
		}
		isTest := testPathRe.MatchString(file)
		symbols, _ := res.(map[string]any)["symbols"].(map[string]any)
		for _, h := range byFile[file] {
			info, _ := symbols[fmt.Sprintf("%d", h.line)].(map[string]any)
			path := ""
			if info != nil {
				path, _ = info["path"].(string)
			}
			if path == "" {
				// No symbol info (script file, top-level code): still strip
				// the raw column and keep the test/blame markers.
				tag := ""
				if isTest {
					tag = "test"
				}
				if age, ok := ages[h.line]; ok {
					if tag != "" {
						tag += " "
					}
					tag += "~" + age
				}
				if tag != "" {
					lines[h.idx] = fmt.Sprintf("%s:%d [%s]:%s", file, h.line, tag, h.rest)
				} else {
					lines[h.idx] = fmt.Sprintf("%s:%d:%s", file, h.line, h.rest)
				}
				continue
			}
			tag := path
			if isTest {
				tag = "test: " + tag
			}
			// What the hit is (definition, call, comment, string; plain
			// references carry no kind), where in the symbol it sits
			// (@line/of-total), how deeply it is nested (dN), whether the
			// line already has a diagnostic (!SEV), and its blame age (~age).
			if kind, ok := info["kind"].(string); ok && kind != "" {
				tag += " " + kind
			}
			if pos, ok := info["pos"].(float64); ok {
				if span, ok := info["span"].(float64); ok && span > 1 {
					tag += fmt.Sprintf(" @%d/%d", int(pos), int(span))
				}
			}
			if depth, ok := info["depth"].(float64); ok && depth > 0 {
				tag += fmt.Sprintf(" d%d", int(depth))
			}
			if diag, ok := info["diag"].(string); ok && diag != "" {
				tag += " !" + diag
			}
			if age, ok := ages[h.line]; ok {
				tag += " ~" + age
			}
			key := file + "|" + path
			if !seenSymbol[key] {
				seenSymbol[key] = true
				decl, _ := info["decl"].(string)
				declLine, _ := info["first"].(float64)
				// Show the signature unless the hit IS the declaration line.
				if decl != "" && int(declLine) != h.line {
					tag += " · " + decl
				}
				if comment, ok := info["comment"].(string); ok && comment != "" {
					tag += " · " + comment
				}
			}
			lines[h.idx] = fmt.Sprintf("%s:%d [%s]:%s", file, h.line, tag, h.rest)
			annotated++
		}
	}
}

// Extensions of files nobody lists a directory to find: images, archives,
// fonts, compiled objects, design sources. A repository's docs/ or assets/
// directory is mostly these, and they crowd out the source the agent asked
// for.
var listFilesSkipExt = map[string]bool{
	".png": true, ".jpg": true, ".jpeg": true, ".gif": true, ".bmp": true,
	".ico": true, ".webp": true, ".svg": true, ".pdf": true, ".ai": true,
	".psd": true, ".sketch": true, ".mp3": true, ".mp4": true, ".mov": true,
	".wav": true, ".ttf": true, ".otf": true, ".woff": true, ".woff2": true,
	".eot": true, ".zip": true, ".gz": true, ".tar": true, ".bz2": true,
	".xz": true, ".7z": true, ".jar": true, ".class": true, ".o": true,
	".a": true, ".so": true, ".dylib": true, ".dll": true, ".exe": true,
	".pyc": true, ".wasm": true, ".bin": true, ".db": true, ".sqlite": true,
}

func runListFiles(root string, args map[string]any) (string, error) {
	target := resolveInRoot(root, args["path"])
	glob, _ := args["glob"].(string)
	var files []string
	cmd := exec.Command("git", "ls-files", "--cached", "--others", "--exclude-standard")
	cmd.Dir = target
	if out, err := cmd.Output(); err == nil {
		files = strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	} else {
		_ = filepath.WalkDir(target, func(path string, d os.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if d.IsDir() {
				if strings.HasPrefix(d.Name(), ".") && path != target {
					return filepath.SkipDir
				}
				return nil
			}
			rel, _ := filepath.Rel(target, path)
			files = append(files, rel)
			return nil
		})
	}
	kept := files[:0]
	var skipped int
	for _, f := range files {
		if f == "" {
			continue
		}
		if glob != "" && !matchPathGlob(glob, f) {
			continue
		}
		if glob == "" && listFilesSkipExt[strings.ToLower(filepath.Ext(f))] {
			skipped++
			continue
		}
		kept = append(kept, f)
	}
	files = kept
	sort.Strings(files)
	var notes []string
	if len(files) > maxListFiles {
		notes = append(notes, fmt.Sprintf("... (truncated at %d files; narrow it with path= or glob=, "+
			"or use workspace_map for files with their declarations)", maxListFiles))
		files = files[:maxListFiles]
	}
	if skipped > 0 {
		notes = append(notes, fmt.Sprintf("... (%d image/binary/archive files not listed; glob= to include them)", skipped))
	}
	if len(files) == 0 && len(notes) == 0 {
		return "(no files)", nil
	}
	return strings.Join(append(files, notes...), "\n"), nil
}

// Match one repo-relative path against a glob, accepting both a bare
// filename pattern ("*.go", matched against the last component) and a path
// pattern ("src/**/*.go"), so that the same glob means here what it means
// in find_symbol and grep.
func matchPathGlob(glob, path string) bool {
	if matchSegments(strings.Split(glob, "/"), strings.Split(path, "/")) {
		return true
	}
	if !strings.Contains(glob, "/") {
		if ok, err := filepath.Match(glob, filepath.Base(path)); err == nil && ok {
			return true
		}
	}
	return false
}

// Segment-wise glob match where "**" stands for any number of path
// segments, including none. filepath.Match alone cannot express that: its
// "*" never crosses a separator.
func matchSegments(pattern, parts []string) bool {
	if len(pattern) == 0 {
		return len(parts) == 0
	}
	if pattern[0] == "**" {
		for i := 0; i <= len(parts); i++ {
			if matchSegments(pattern[1:], parts[i:]) {
				return true
			}
		}
		return false
	}
	if len(parts) == 0 {
		return false
	}
	if ok, err := filepath.Match(pattern[0], parts[0]); err != nil || !ok {
		return false
	}
	return matchSegments(pattern[1:], parts[1:])
}

// callTool executes one tool and returns its text result.
func callTool(name string, args map[string]any, root string) (string, error) {
	if lspToolNames[name] {
		// "from" and "to" belong to move_file; they name paths exactly as
		// "file" does and have to be rooted the same way.
		for _, key := range []string{"file", "from", "to"} {
			if _, ok := args[key]; !ok {
				continue
			}
			resolved := map[string]any{}
			for k, v := range args {
				resolved[k] = v
			}
			resolved[key] = resolveInRoot(root, args[key])
			args = resolved
		}
		switch name {
		case "ts_query", "find_symbol", "workspace_map", "workspace_symbols", "install_language",
			"replace_symbol_body", "replace_symbol_lines", "insert_after_symbol", "insert_before_symbol", "undo_edit", "rename_symbol", "check_project",
			"create_file", "move_file", "delete_file":
			resolved := map[string]any{}
			for k, v := range args {
				resolved[k] = v
			}
			resolved["root"] = root
			args = resolved
		}
		if list, ok := args["files"].([]any); ok {
			resolvedList := make([]any, len(list))
			for i, v := range list {
				resolvedList[i] = resolveInRoot(root, v)
			}
			resolved := map[string]any{}
			for k, v := range args {
				resolved[k] = v
			}
			resolved["files"] = resolvedList
			args = resolved
		}
		if headlessRoot() != "" {
			// The server autosaves after edits; tools word their notes accordingly.
			resolved := map[string]any{}
			for k, v := range args {
				resolved[k] = v
			}
			resolved["headless"] = true
			args = resolved
		}
		result, err := nvimCall(name, args)
		if err != nil {
			return "", err
		}
		text, err := renderJSON(result)
		if err != nil {
			return "", err
		}
		out := string(text)
		// Partial buffer reads get the same breadcrumb as partial file reads.
		if name == "buffer_lines" {
			if first, ok := args["first"].(float64); ok {
				if file, ok := args["file"].(string); ok {
					if crumb := readContext(file, int(first)); crumb != "" {
						out = crumb + "\n" + out
					}
				}
			}
		}
		return out, nil
	}
	switch name {
	case "read_file":
		out, err := runReadFile(root, args)
		if err == nil && os.Getenv("AGENT99_NO_LSP") == "" {
			// Let the editor's code window follow the read (best-effort).
			nvimCall("ui_follow", map[string]any{
				"file": resolveInRoot(root, args["path"]),
				"line": argInt(args, "offset", 1),
			})
		}
		return out, err
	case "grep":
		return runGrep(root, args)
	case "list_files":
		return runListFiles(root, args)
	}
	return "", fmt.Errorf("unknown tool: %s", name)
}
