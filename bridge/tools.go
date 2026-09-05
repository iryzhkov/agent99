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

var lspToolNames = func() map[string]bool {
	set := map[string]bool{}
	for _, t := range lspTools {
		set[t.Name] = true
	}
	// The debugger tools run in Neovim too, through the same transport.
	for _, t := range debugTools {
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
	if scanner.Err() != nil {
		// A line over the buffer cap stops the count early. The count only
		// decides whether a read returns a skim instead of the text, so a
		// file that big is exactly one that should: report it as large.
		return autoSkimThreshold + n
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

// skimHasOutline reports whether a skim reply carries at least one outline
// entry for its first file.
func skimHasOutline(res any) bool {
	m, ok := res.(map[string]any)
	if !ok {
		return false
	}
	files, ok := m["files"].([]any)
	if !ok || len(files) == 0 {
		return false
	}
	first, ok := files[0].(map[string]any)
	if !ok {
		return false
	}
	// One or two entries (a data file with a single top-level key) do not
	// stand in for the content the way a real outline does.
	outline, ok := first["outline"].([]any)
	return ok && len(outline) >= 3
}

func runReadFile(root string, args map[string]any) (string, error) {
	path := resolveInRoot(root, args["path"])
	explicit := args["offset"] != nil || args["limit"] != nil
	if !explicit && os.Getenv("AGENT99_NO_LSP") == "" {
		if n := countLines(path); n > autoSkimThreshold {
			// A skim only replaces the content when it has an outline. A
			// file nothing can outline (a log, a data dump, a grammar
			// without declarations) would otherwise come back as "no
			// outline; read it instead" from the read itself.
			if res, err := nvimCall("skim", map[string]any{"files": []any{path}}); err == nil && skimHasOutline(res) {
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
	tests, _ := args["tests"].(string)
	kind, _ := args["kind"].(string)
	if kind != "" && !grepKinds[kind] {
		return "", fmt.Errorf("kind must be one of def, call, comment, string, code")
	}
	if tests != "" && tests != "exclude" && tests != "only" {
		return "", fmt.Errorf("tests must be exclude or only")
	}
	if kind != "" {
		// Filtering drops individual match lines, which would leave the
		// context lines around them orphaned under the wrong hit. A filtered
		// search is a list, not a reading window.
		ctx = 0
		ctxArg = "-C0"
	}
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
	if searchDir != "" {
		absolutizeGrepPaths(lines, searchDir)
	}
	// Path-based, so it is exact and costs nothing: no classifier involved,
	// and it happens before truncation so the cap applies to hits the caller
	// actually asked for.
	var testsFiltered int
	if tests == "exclude" || tests == "only" {
		kept := lines[:0]
		for _, l := range lines {
			isTest := testPathRe.MatchString(grepHitPath(l, searchDir))
			if (tests == "only") == isTest {
				kept = append(kept, l)
			} else {
				testsFiltered++
			}
		}
		lines = kept
	}
	var truncated int
	if len(lines) > maxGrepLines {
		truncated = len(lines) - maxGrepLines
		lines = lines[:maxGrepLines]
	}
	drop, unclassified := annotateGrepHits(lines, blame, kind)
	if len(drop) > 0 {
		kept := lines[:0]
		for i, l := range lines {
			if !drop[i] {
				kept = append(kept, l)
			}
		}
		lines = kept
	}
	var notes []string
	if truncated > 0 {
		notes = append(notes, fmt.Sprintf("... (%d more matches not shown; narrow with path=, glob= or a tighter pattern)", truncated))
	}
	if testsFiltered > 0 {
		notes = append(notes, fmt.Sprintf("... (%d hits in test files left out by tests=%s)", testsFiltered, tests))
	}
	if unclassified > 0 {
		notes = append(notes, fmt.Sprintf("... (%d hits could not be classified and so are not shown; "+
			"drop kind= to see them)", unclassified))
	}
	if len(lines) == 0 && len(notes) == 0 {
		return "(no matches)", nil
	}
	return strings.Join(append(lines, notes...), "\n"), nil
}

// A match line is "path:line:col:text" and a context line is
// "path-line-text", so the path ends at the first separator that is followed
// by a line number and another separator. Splitting on the first ":" or "-"
// instead would cut "/tmp/agent99-headless-7wwbv/proj/x.go:2:..." down to
// "/tmp/agent99", which is a directory name away from being a real bug in
// any repository checked out under a hyphenated path.
var grepHitPathRe = regexp.MustCompile(`^(.*?)[:-]\d+[:-]`)

// The path part of a searcher output line, relative to root, for filters that
// work on paths. Stripping root first keeps the pattern away from whatever
// the temporary or checkout directory happens to be called.
func grepHitPath(line, root string) string {
	rest := line
	if root != "" && strings.HasPrefix(rest, root+"/") {
		rest = rest[len(root)+1:]
	}
	if m := grepHitPathRe.FindStringSubmatch(rest); m != nil {
		return m[1]
	}
	return rest
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
// Kinds a caller can filter a search down to. "code" is the useful one in
// practice: an identifier that also appears in prose above every use of it
// produces a page of doc-comment hits that answer nothing.
var grepKinds = map[string]bool{
	"def": true, "call": true, "comment": true, "string": true, "code": true,
}

func kindMatches(filter, kind string) bool {
	switch filter {
	case "":
		return true
	case "code":
		return kind != "comment" && kind != "string"
	default:
		return kind == filter
	}
}

// Annotates each hit in place and, when kindFilter is set, reports which hits
// did not match it and how many could not be classified at all. Classification
// comes from the editor, so it is bounded (see the caps below); a filter whose
// answer depends on hits past that bound would be a lie, so the count of
// unclassified hits is returned for the caller to disclose.
func annotateGrepHits(lines []string, blame bool, kindFilter string) (drop map[int]bool, unclassified int) {
	drop = map[int]bool{}
	if os.Getenv("AGENT99_NO_LSP") != "" {
		return drop, 0
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
	// Classifying costs one editor round trip per file, so it is capped. A
	// caller filtering by kind is asking for exactly that work, though, so
	// the caps are raised rather than silently truncating their filter.
	maxFiles, maxHits := 8, 60
	if kindFilter != "" {
		maxFiles, maxHits = 40, 400
	}
	for fi, file := range order {
		if fi >= maxFiles || annotated >= maxHits {
			for _, rest := range order[fi:] {
				unclassified += len(byFile[rest])
			}
			return drop, unclassified
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
			// Editor unreachable; leave the rest plain too.
			for _, rest := range order[fi:] {
				unclassified += len(byFile[rest])
			}
			return drop, unclassified
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
			hitKind := ""
			if info != nil {
				path, _ = info["path"].(string)
				hitKind, _ = info["kind"].(string)
			}
			// A blank kind is an answer, not a gap: the classifier walked the
			// tree and found the hit is a plain reference - definitively not
			// a comment, string, definition or call. Genuinely unknown hits
			// are the ones never classified at all, counted where the caps
			// are applied above.
			if kindFilter != "" && !kindMatches(kindFilter, hitKind) {
				drop[h.idx] = true
				continue
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
	return drop, unclassified
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
		// "file" does and have to be rooted the same way. The debugger's
		// paths are "program" and "cwd"; its "to" is an object, not a path.
		pathKeys := []string{"file", "from", "to"}
		if debugToolNames[name] {
			pathKeys = []string{"file", "program", "cwd"}
		}
		for _, key := range pathKeys {
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
		// debug_continue's run-to target carries its own file.
		if to, ok := args["to"].(map[string]any); ok && name == "debug_continue" {
			resolvedTo := map[string]any{}
			for k, v := range to {
				resolvedTo[k] = v
			}
			resolvedTo["file"] = resolveInRoot(root, to["file"])
			resolved := map[string]any{}
			for k, v := range args {
				resolved[k] = v
			}
			resolved["to"] = resolvedTo
			args = resolved
		}
		switch name {
		case "ts_query", "find_symbol", "workspace_map", "workspace_symbols", "install_language",
			"replace_symbol_body", "replace_symbol_lines", "insert_after_symbol", "insert_before_symbol", "undo_edit", "rename_symbol", "check_project",
			"create_file", "move_file", "delete_file", "move_symbols":
			resolved := map[string]any{}
			for k, v := range args {
				resolved[k] = v
			}
			resolved["root"] = root
			args = resolved
		}
		if debugToolNames[name] {
			// Every debugger tool needs the root: defaults for cwd, the
			// external-frame boundary, and the adapter lookup.
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
