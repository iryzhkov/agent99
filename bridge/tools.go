package main

// Tool definitions and execution. The LSP tools run inside Neovim (see
// nvim.go and the plugin's lua/agent99/lsp.lua); the file tools run here,
// rooted at the project.

import (
	"bufio"
	"context"
	"encoding/json"
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
			"file":   map[string]any{"type": "string", "description": "Path to the file (absolute, or relative to the project root)."},
			"line":   map[string]any{"type": "integer", "description": "1-based line number."},
			"symbol": map[string]any{"type": "string", "description": "Symbol text on that line; its first occurrence marks the position. Prefer this over col."},
			"col":    map[string]any{"type": "integer", "description": "Optional 1-based byte column, as an alternative to symbol."},
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
			"file": map[string]any{"type": "string", "description": "Path to the file (absolute, or relative to the project root)."},
		},
		"required": []string{"file"},
	}
}

// lspTools are executed inside Neovim, against its live LSP clients.
var lspTools = []tool{
	positionTool("definition",
		"Go to the definition of the symbol at a position, via the live LSP client "+
			"in the user's Neovim. Returns file/line locations with a one-line preview."),
	positionTool("type_definition",
		"Go to the type definition of the symbol at a position (the type of a "+
			"variable rather than the variable itself)."),
	positionTool("implementation",
		"List implementations of the interface/abstract symbol at a position."),
	positionTool("references",
		"List all references to the symbol at a position across the whole project, "+
			"including the declaration. Use this to see every caller/usage before "+
			"changing a signature or behavior."),
	positionTool("hover",
		"Hover information for the symbol at a position: resolved type signature "+
			"and documentation, as the editor would show it. The fastest way to learn "+
			"a function's exact signature and doc comment."),
	positionTool("expand_symbol",
		"One-call combo: resolve the definition of the symbol at a position, then "+
			"return the FULL SOURCE of the defining symbol (whole function/class body) "+
			"plus its hover signature. Prefer this over calling definition and then "+
			"reading the target file - it saves a round-trip."),
	positionTool("incoming_calls",
		"Call hierarchy: functions that call the function at a position, with the "+
			"line numbers of each call site."),
	positionTool("outgoing_calls",
		"Call hierarchy: functions called by the function at a position."),
	positionTool("code_actions",
		"List the LSP code actions available at a position (quick fixes, "+
			"refactorings, imports...). Returns a token and an indexed list of action "+
			"titles; apply one with apply_code_action."),
	{
		Name: "apply_code_action",
		Description: "Apply one code action from a previous code_actions call, by its " +
			"token and index. The edit is performed by the editor itself (safe, " +
			"possibly multi-file); returns the list of changed files. Changes stay " +
			"unsaved in editor buffers - inspect them with buffer_lines.",
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
		Name: "skim",
		Description: "Rough structure of up to 20 files in ONE call: every " +
			"function/class/method declaration line with its line number, nested to " +
			"show containment (via treesitter, LSP fallback). An order of magnitude " +
			"cheaper than reading files - use it FIRST to explore unfamiliar files, " +
			"then read only the regions that matter.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"files": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "Paths of the files to skim (1-20), absolute or relative to the project root.",
				},
			},
			"required": []string{"files"},
		},
	},
	{
		Name: "ts_query",
		Description: "Structural search: run a treesitter s-expression query over many " +
			"files in one call. Precise where grep is textual - distinguish declarations " +
			"from usages, match calls by shape, capture sub-nodes with @name. Supports " +
			"#eq?/#match? predicates. Example (Lua): (function_declaration name: (_) @name). " +
			"Node type names are grammar-specific; if the query fails to compile, check " +
			"the constructs with skim first. Returns file:line plus the captured text.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"query": map[string]any{"type": "string", "description": "Treesitter query (s-expression) with at least one @capture."},
				"files": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "Files to search (optional if glob is given).",
				},
				"glob": map[string]any{"type": "string", "description": "Optional glob relative to the project root, e.g. \"**/*.lua\"."},
			},
			"required": []string{"query"},
		},
	},
	{
		Name: "find_symbol",
		Description: "Look up symbols by name path across files and optionally fetch their " +
			"FULL SOURCE. Name paths use \"/\" for nesting (\"MyClass/method\") or just the " +
			"name (\"vec2_add\"). With include_body=true this is the cheapest way to read " +
			"exactly one function/class instead of a whole file. Returns name_path, kind, " +
			"file, absolute line range, and (optionally) the body numbered RELATIVE to the " +
			"symbol (declaration = 1) - those numbers feed replace_symbol_lines directly.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"name":         map[string]any{"type": "string", "description": "Symbol name or name path (suffix and substring matching supported)."},
				"file":         map[string]any{"type": "string", "description": "One file to search."},
				"files":        map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "Several files to search."},
				"glob":         map[string]any{"type": "string", "description": "Glob relative to the project root, e.g. \"**/*.go\"."},
				"include_body": map[string]any{"type": "boolean", "description": "Return the full source of well-matching symbols."},
			},
			"required": []string{"name"},
		},
	},
	{
		Name: "replace_symbol_body",
		Description: "Replace one whole symbol (function/class/method) in a file with new " +
			"source, addressed by name path instead of line numbers. The edit is applied " +
			"to the editor buffer immediately and is tracked (the user can revert). Provide " +
			"the complete new symbol including its declaration line, matching the file's " +
			"indentation. The symbol's range does NOT include doc comments above the " +
			"declaration - never repeat them in the body. Do not use this on the user's " +
			"selected region; that region is changed only via the <replacement> reply.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":      map[string]any{"type": "string", "description": "File containing the symbol."},
				"name_path": map[string]any{"type": "string", "description": "Symbol name path (use the full path if the name is ambiguous)."},
				"body":      map[string]any{"type": "string", "description": "Complete replacement source for the symbol."},
			},
			"required": []string{"file", "name_path", "body"},
		},
	},
	{
		Name: "replace_symbol_lines",
		Description: "Replace a SLICE of a symbol, addressed by line numbers RELATIVE to " +
			"the symbol's first line (declaration = 1) - the same numbering find_symbol " +
			"bodies use. Prefer this over replace_symbol_body for small changes inside a " +
			"large function: you only send the changed lines. Applied to the editor " +
			"buffer immediately and tracked; returns fresh diagnostics.",
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
		Name: "insert_after_symbol",
		Description: "Insert new source immediately after a symbol (e.g. a new function " +
			"below an existing one), addressed by name path. Applied to the editor buffer " +
			"immediately and tracked.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":      map[string]any{"type": "string", "description": "File containing the anchor symbol."},
				"name_path": map[string]any{"type": "string", "description": "Anchor symbol name path."},
				"text":      map[string]any{"type": "string", "description": "Source to insert (a separating blank line is added automatically)."},
			},
			"required": []string{"file", "name_path", "text"},
		},
	},
	{
		Name: "insert_before_symbol",
		Description: "Insert new source immediately before a symbol (e.g. an import, a " +
			"helper, a decorator), addressed by name path. Applied to the editor buffer " +
			"immediately and tracked.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":      map[string]any{"type": "string", "description": "File containing the anchor symbol."},
				"name_path": map[string]any{"type": "string", "description": "Anchor symbol name path."},
				"text":      map[string]any{"type": "string", "description": "Source to insert (a separating blank line is added automatically)."},
			},
			"required": []string{"file", "name_path", "text"},
		},
	},
	{
		Name: "document_symbols",
		Description: "Outline of one file: every function/class/method with its line " +
			"number, nested to show structure. Cheaper than reading the file when you " +
			"only need its shape.",
		InputSchema: fileOnlySchema(),
	},
	{
		Name: "workspace_symbols",
		Description: "Fuzzy-search symbol names (functions, classes, methods, ...) " +
			"across the whole project. Use this to locate something by name when you " +
			"do not know which file it lives in.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"query": map[string]any{"type": "string", "description": "Symbol name or fragment."},
			},
			"required": []string{"query"},
		},
	},
	{
		Name: "diagnostics",
		Description: "Current LSP diagnostics (errors, warnings, hints) for one file, " +
			"as shown in the editor. Diagnostics that the language server can fix itself " +
			"carry a quick_fixes list of action titles: apply those with " +
			"code_actions + apply_code_action instead of writing the fix by hand.",
		InputSchema: fileOnlySchema(),
	},
	{
		Name: "buffer_lines",
		Description: "Read a file as the editor currently sees it, including UNSAVED " +
			"changes, with line numbers. Prefer this over reading from disk for any file " +
			"the user has open: the on-disk content may be stale.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"file":  map[string]any{"type": "string", "description": "Path to the file (absolute, or relative to the project root)."},
				"first": map[string]any{"type": "integer", "description": "Optional 1-based first line (default 1)."},
				"last":  map[string]any{"type": "integer", "description": "Optional 1-based last line (default: end of buffer)."},
			},
			"required": []string{"file"},
		},
	},
}

// fileTools run in this process; only the "agent" subcommand exposes them
// (the claude provider has its own Read/Grep/Glob).
var fileTools = []tool{
	{
		Name: "read_file",
		Description: "Read a file from disk with line numbers. Use buffer_lines instead " +
			"for files the user has open in the editor (they may have unsaved changes).",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"path":   map[string]any{"type": "string", "description": "File path, absolute or relative to the project root."},
				"offset": map[string]any{"type": "integer", "description": "1-based first line to read (default 1)."},
				"limit":  map[string]any{"type": "integer", "description": fmt.Sprintf("Maximum number of lines (default %d).", maxReadLines)},
			},
			"required": []string{"path"},
		},
	},
	{
		Name: "grep",
		Description: "Search file contents in the project with a regular expression " +
			"(ripgrep/grep syntax). Matches come with context lines and a rich tag: " +
			"path:line [Symbol kind @pos/len dN !SEV ~age - signature - doc-comment]. " +
			"kind says what the hit IS (def, call, comment, string; plain references " +
			"are untagged), @pos/len locates it inside the symbol, dN is loop/branch " +
			"nesting depth, !ERROR/!WARN means the line already has that diagnostic, " +
			"'test:' prefixes hits in test files, ~age (with blame=true) is when the " +
			"line last changed. Signature and doc-comment appear on the first hit per " +
			"symbol. You usually do NOT need a follow-up read to understand a hit.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"pattern": map[string]any{"type": "string", "description": "Regular expression to search for."},
				"path":    map[string]any{"type": "string", "description": "Optional subdirectory or file to search (default: project root)."},
				"glob":    map[string]any{"type": "string", "description": "Optional filename filter, e.g. \"*.lua\" or \"**/*.go\"."},
				"context": map[string]any{"type": "integer", "description": "Context lines around each match (default 2, max 10)."},
				"blame":   map[string]any{"type": "boolean", "description": "Also show when each hit line last changed (git blame; slower)."},
			},
			"required": []string{"pattern"},
		},
	},
	{
		Name:        "list_files",
		Description: "List files in the project (respects .gitignore in git repos).",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"path": map[string]any{"type": "string", "description": "Optional subdirectory (default: project root)."},
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
				pretty, merr := json.MarshalIndent(res, "", "  ")
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
	var cmd *exec.Cmd
	if _, err := exec.LookPath("rg"); err == nil {
		cargs := []string{"-n", "--column", "--no-heading", "-S", ctxArg}
		if glob != "" {
			cargs = append(cargs, "-g", glob)
		}
		cargs = append(cargs, "-e", pattern, target)
		cmd = exec.Command("rg", cargs...)
	} else {
		cargs := []string{"-rnIE", ctxArg}
		if glob != "" {
			cargs = append(cargs, "--include="+glob)
		}
		cargs = append(cargs, "-e", pattern, target)
		cmd = exec.Command("grep", cargs...)
	}
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
	annotateGrepHits(lines, blame)
	return strings.Join(lines, "\n"), nil
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

func runListFiles(root string, args map[string]any) (string, error) {
	target := resolveInRoot(root, args["path"])
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
	sort.Strings(files)
	if len(files) > maxListFiles {
		files = append(files[:maxListFiles],
			fmt.Sprintf("... (truncated at %d files)", maxListFiles))
	}
	if len(files) == 0 {
		return "(no files)", nil
	}
	return strings.Join(files, "\n"), nil
}

// callTool executes one tool and returns its text result.
func callTool(name string, args map[string]any, root string) (string, error) {
	if lspToolNames[name] {
		if _, ok := args["file"]; ok {
			resolved := map[string]any{}
			for k, v := range args {
				resolved[k] = v
			}
			resolved["file"] = resolveInRoot(root, args["file"])
			args = resolved
		}
		if name == "ts_query" || name == "find_symbol" {
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
		result, err := nvimCall(name, args)
		if err != nil {
			return "", err
		}
		text, err := json.MarshalIndent(result, "", "  ")
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
