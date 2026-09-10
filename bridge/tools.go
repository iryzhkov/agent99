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
	"strconv"
	"strings"
	"time"
)

const (
	maxToolOutputChars = 30000
	maxGrepLines       = 200
	// How many searcher output lines are read past the cap before the
	// search is stopped: enough to count what a truncation note reports,
	// not enough to let a pattern like "." read a whole tree.
	maxGrepScan  = 20000
	maxListFiles = 500
	maxReadLines = 2000
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
func readContext(ses session, file string, line int) string {
	if os.Getenv("AGENT99_NO_LSP") != "" || line <= 1 {
		return ""
	}
	res, err := nvimCall(ses.Socket, "enclosing_symbols",
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

func runReadFile(ses session, args map[string]any) (string, error) {
	path := resolveInRoot(ses.Root, args["path"])
	explicit := args["offset"] != nil || args["limit"] != nil
	if !explicit && os.Getenv("AGENT99_NO_LSP") == "" {
		if n := countLines(path); n > autoSkimThreshold {
			// A skim only replaces the content when it has an outline. A
			// file nothing can outline (a log, a data dump, a grammar
			// without declarations) would otherwise come back as "no
			// outline; read it instead" from the read itself.
			if res, err := nvimCall(ses.Socket, "skim", map[string]any{"files": []any{path}}); err == nil && skimHasOutline(res) {
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
	total, next := 0, 0
	for i := 1; scanner.Scan(); i++ {
		total = i
		if i < offset {
			continue
		}
		if i >= offset+limit {
			next = i
			break
		}
		out = append(out, fmt.Sprintf("%d: %s", i, scanner.Text()))
	}
	if next > 0 {
		// Read on to the end without keeping the lines, so the hint can say
		// how much of the file is still ahead and not only where to resume.
		// A truncated read otherwise costs a second call just to find out
		// whether one more is worth making.
		for scanner.Scan() {
			total++
		}
		out = append(out, fmt.Sprintf(
			"... (truncated: lines %d-%d of %d; continue with offset=%d)",
			offset, next-1, total, next))
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	if len(out) == 0 {
		return "(empty range)", nil
	}
	if explicit {
		if crumb := readContext(ses, path, offset); crumb != "" {
			out = append([]string{crumb}, out...)
		}
	}
	return strings.Join(out, "\n"), nil
}

func runGrep(ses session, args map[string]any) (string, error) {
	root := ses.Root
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
	// files= was accepted and dropped: one file was asked for and three came
	// back, from the whole tree.
	var namedFiles []string
	if list, ok := args["files"].([]any); ok {
		for _, v := range list {
			if s, ok := v.(string); ok && s != "" {
				namedFiles = append(namedFiles, resolveInRoot(root, s))
			}
		}
	}
	blame, _ := args["blame"].(bool)
	asText, _ := args["text"].(bool)
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
	// The targets the searcher is given: the files named, else the path (or
	// the root) the call scoped itself to.
	searchTargets := []string{searchTarget}
	if len(namedFiles) > 0 {
		searchTargets = nil
		for _, f := range namedFiles {
			if rel, err := filepath.Rel(searchDir, f); err == nil && !strings.HasPrefix(rel, "..") {
				searchTargets = append(searchTargets, rel)
			} else {
				searchTargets = append(searchTargets, f)
			}
		}
	}
	ctxCancel, cancel := context.WithCancel(context.Background())
	defer cancel()
	var cmd *exec.Cmd
	usedRg := false
	if _, err := exec.LookPath("rg"); err == nil {
		usedRg = true
		// --sort path costs rg its parallelism but makes the output
		// deterministic; without it two identical greps are not
		// byte-identical, which defeats the duplicate-result guard.
		// -H keeps the filename even for a single-file target, which the
		// annotator's path:line:col parsing depends on.
		cargs := []string{"-H", "-n", "--column", "--no-heading", "-S", "--sort", "path", ctxArg}
		if asText {
			// A source file that happens to hold a NUL byte is still source.
			cargs = append(cargs, "--text")
		} else {
			// Without this a file whose NUL comes before the first match is
			// skipped in silence - a .go file with three matches around one
			// NUL byte answered "(no matches)". With it, ripgrep says which
			// file it gave up on, and the reply can pass that on.
			cargs = append(cargs, "--binary")
		}
		if glob != "" {
			cargs = append(cargs, "-g", glob)
		}
		cargs = append(cargs, "-e", pattern)
		cargs = append(cargs, searchTargets...)
		cmd = exec.CommandContext(ctxCancel, "rg", cargs...)
	} else {
		cargs := []string{"-rnHE", ctxArg}
		if asText {
			cargs = append(cargs, "-a")
		} else {
			cargs = append(cargs, "-I")
		}
		if glob != "" {
			cargs = append(cargs, "--include="+glob)
		}
		cargs = append(cargs, "-e", pattern)
		cargs = append(cargs, searchTargets...)
		cmd = exec.CommandContext(ctxCancel, "grep", cargs...)
	}
	cmd.Dir = searchDir
	var stderr tailBuffer
	cmd.Stderr = &stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", fmt.Errorf("grep failed: %v", err)
	}
	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("grep failed: %v", err)
	}
	// The output is read as it comes and kept only up to the cap: a broad
	// pattern over a large tree produces megabytes that would otherwise be
	// buffered whole before being thrown away. Past the cap the rest is
	// counted (bounded by maxGrepScan, after which the searcher is killed)
	// so the truncation note can say how much was left out.
	//
	// The tests= filter is path-based, so it is exact and costs nothing:
	// no classifier involved, and it happens before the cap so that the cap
	// applies to hits the caller actually asked for. rg's "--" separators
	// between context groups are not hits: they are passed through, never
	// counted, and collapsed where the filter emptied a group.
	var lines []string
	var stoppedEarly []string
	var testsFiltered, truncated, scanned int
	filtering := tests == "exclude" || tests == "only"
	capped := false
	reader := bufio.NewReader(stdout)
	for {
		l, rerr := reader.ReadString('\n')
		if l == "" && rerr != nil {
			break
		}
		l = strings.TrimRight(l, "\n")
		scanned++
		if l == "--" {
			if len(lines) > 0 && lines[len(lines)-1] != "--" && len(lines) < maxGrepLines {
				lines = append(lines, l)
			}
		} else if binaryPath := binaryStopPath(l); binaryPath != "" {
			// ripgrep gives up on a file holding a NUL byte after its first
			// match and says so on stdout. The line is not a hit, and left
			// among the results it reads as one while the rest of that file
			// went unsearched - a TypeScript file with one stray NUL was
			// searched to its 94kth byte and no further, silently.
			if searchDir != "" {
				binaryPath = filepath.Join(searchDir, binaryPath)
			}
			stoppedEarly = append(stoppedEarly, binaryPath)
		} else {
			if searchDir != "" {
				l = absolutizeGrepPath(l, searchDir)
			}
			// Context lines travel with their hit but are not hits: the
			// counts in the notes are of hits only.
			path, isHit := grepHitPath(l, searchDir)
			keep := !filtering || (tests == "only") == testPathRe.MatchString(path)
			switch {
			case !keep:
				if isHit {
					testsFiltered++
				}
			case len(lines) < maxGrepLines:
				lines = append(lines, l)
			case isHit:
				truncated++
			}
		}
		if rerr != nil {
			break
		}
		if scanned >= maxGrepScan {
			capped = true
			cancel()
			break
		}
	}
	if len(lines) > 0 && lines[len(lines)-1] == "--" {
		lines = lines[:len(lines)-1]
	}
	// ripgrep announces a file it gave up on only when it had already found a
	// match in it. A NUL in the first block makes it classify the file as
	// binary and skip it in silence, and then exit 1: three matches in a .go
	// file came back as "(no matches)", an empty answer that looks like an
	// answer. Only an empty result is worth a second pass, and an empty
	// search is the cheap one to repeat.
	// Only when nothing was found at all - not when the tests= filter or the
	// kind= classifier removed the hits, which reported the filtered-out
	// files as if they held a NUL byte and the search had been incomplete.
	if len(lines) == 0 && len(stoppedEarly) == 0 && testsFiltered == 0 && truncated == 0 &&
		!asText && usedRg {
		// The targets the first pass was given, not the path it scoped
		// itself to: a files=-scoped search that found nothing named the
		// whole tree's binary-looking files as though the caller had asked
		// about them.
		stoppedEarly = append(stoppedEarly, textOnlyMatches(pattern, glob, searchDir, searchTargets)...)
	}
	waitErr := cmd.Wait()
	if capped {
		// The searcher was stopped, so its exit status says nothing.
		waitErr = nil
	}
	var notes []string
	if waitErr != nil {
		// Exit code 1 just means "no matches" for both rg and grep. Code 2
		// is an error - a bad regex, an unreadable path - which may still
		// have come after matches; those are kept and the error becomes a
		// note, so the caller sees both.
		ee, isExit := waitErr.(*exec.ExitError)
		if isExit && ee.ExitCode() == 1 && len(lines) == 0 {
			if len(stoppedEarly) > 0 {
				return binaryNote(stoppedEarly), nil
			}
			// A glob that matches no file at all answers the same as a
			// pattern that is not in the code, and the two need different
			// fixes. find_symbol and workspace_map say which; this said
			// "(no matches)" and left a typo'd glob looking like an answer.
			if glob != "" && usedRg && !globMatchesAnything(glob, searchDir, searchTargets) {
				return fmt.Sprintf("(no matches: the glob %q matched no files under %s, so "+
					"nothing was searched. A glob is matched against the path from the root, "+
					"so subdirectories need a \"**/\" prefix)", glob, rel(root, searchDir)), nil
			}
			return "(no matches)", nil
		}
		detail := stderr.String()
		if detail == "" {
			detail = waitErr.Error()
		}
		if len(lines) == 0 {
			return "", fmt.Errorf("grep failed: %s", detail)
		}
		notes = append(notes, "... (the search also reported an error: "+
			strings.ReplaceAll(detail, "\n", "; ")+")")
	}
	drop, unclassified := annotateGrepHits(ses, lines, blame, kind)
	if len(drop) > 0 {
		kept := lines[:0]
		for i, l := range lines {
			if !drop[i] {
				kept = append(kept, l)
			}
		}
		lines = kept
	}
	if capped {
		notes = append(notes, fmt.Sprintf("... (more than %d further matches not shown; narrow with path=, glob= or a tighter pattern)", truncated))
	} else if truncated > 0 {
		notes = append(notes, fmt.Sprintf("... (%d more matches not shown; narrow with path=, glob= or a tighter pattern)", truncated))
	}
	if testsFiltered > 0 {
		where := "in test files"
		if tests == "only" {
			where = "outside test files"
		}
		notes = append(notes, fmt.Sprintf("... (%d hits %s left out by tests=%s)", testsFiltered, where, tests))
	}
	if unclassified > 0 && kind != "" {
		notes = append(notes, fmt.Sprintf("... (%d hits could not be classified and so are not shown; "+
			"drop kind= to see them)", unclassified))
	} else if unclassified > 0 {
		notes = append(notes, fmt.Sprintf("... (%d hits are shown unannotated: the classifier stops after "+
			"the first files; narrow with path= or glob= to annotate them)", unclassified))
	}
	if len(stoppedEarly) > 0 && !asText {
		notes = append(notes, binaryNote(stoppedEarly))
	}
	if len(lines) == 0 && len(notes) == 0 {
		return "(no matches)", nil
	}
	return strings.Join(append(lines, notes...), "\n"), nil
}

// Whether a glob matches any file at all in the search scope.
func globMatchesAnything(glob, dir string, targets []string) bool {
	args := append([]string{"--files", "-g", glob}, targets...)
	cmd := exec.Command("rg", args...)
	cmd.Dir = dir
	out, err := cmd.Output()
	return err == nil && strings.TrimSpace(string(out)) != ""
}

// A path for a message: relative to the root when it is under it.
func rel(root, path string) string {
	if r, err := filepath.Rel(root, path); err == nil && !strings.HasPrefix(r, "..") {
		if r == "." {
			return filepath.Base(root)
		}
		return r
	}
	return path
}

// The files a search matches only when they are read as text: those holding
// a NUL byte, which the searcher skips or stops at. Run only for a search
// that came back empty, where the alternative is answering "(no matches)"
// about a file full of them.
func textOnlyMatches(pattern, glob, dir string, targets []string) []string {
	args := []string{"--text", "--files-with-matches", "-m", "1", "-S"}
	if glob != "" {
		args = append(args, "-g", glob)
	}
	args = append(args, "-e", pattern)
	args = append(args, targets...)
	cmd := exec.Command("rg", args...)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	var files []string
	for _, f := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if f == "" {
			continue
		}
		if dir != "" {
			f = filepath.Join(dir, f)
		}
		files = append(files, f)
	}
	return files
}

// What the reply says about files the search could not read in full.
func binaryNote(files []string) string {
	shown := files
	if len(shown) > 3 {
		shown = shown[:3]
	}
	return fmt.Sprintf("... (%d file(s) hold a NUL byte: they are read only as far as it, or not at "+
		"all, so matches in them are missing from this answer: %s. Pass text=true to search them in "+
		"full)", len(files), strings.Join(shown, ", "))
}

// The path out of ripgrep's "<path>: binary file matches (found "\0" byte
// around offset N)" and "WARNING: stopped searching binary file after match"
// lines, which arrive on stdout among the results. "" for any other line.
func binaryStopPath(l string) string {
	for _, marker := range []string{
		": WARNING: stopped searching binary file after match",
		": binary file matches",
	} {
		if i := strings.Index(l, marker); i > 0 {
			// A hit is "path:line:col:text", so anything with a colon before
			// the marker is a match whose text quotes it, not the warning.
			if path := l[:i]; !strings.Contains(path, ":") {
				return path
			}
		}
	}
	return ""
}

// A match line is "path:line:col:text" and a context line is
// "path-line-text", so the path ends at the first separator that is followed
// by a line number and another separator. Splitting on the first ":" or "-"
// instead would cut "/tmp/agent99-headless-7wwbv/proj/x.go:2:..." down to
// "/tmp/agent99", which is a directory name away from being a real bug in
// any repository checked out under a hyphenated path.
//
// The groups are path, separator, line number, separator: a hit has ":" for
// both separators, a context line "-".
var grepHitPathRe = regexp.MustCompile(`^(.*?)([:-])(\d+)([:-])`)

// editorUnreachable tells a transport failure (nothing answers on the
// socket, or nothing answered in time) from an error the tool itself
// returned. The first makes every further call pointless; the second is
// about one call only.
func editorUnreachable(err error) bool {
	msg := err.Error()
	return strings.HasPrefix(msg, "nvim RPC failed") || strings.HasPrefix(msg, "timed out after") ||
		strings.HasPrefix(msg, "no Neovim to talk to")
}

// The path part of a searcher output line, relative to root, for filters that
// work on paths. Stripping root first keeps the pattern away from whatever
// the temporary or checkout directory happens to be called.
func grepHitPath(line, root string) (path string, isHit bool) {
	rest := line
	if root != "" && strings.HasPrefix(rest, root+"/") {
		rest = rest[len(root)+1:]
	}
	if m := grepHitPathRe.FindStringSubmatch(rest); m != nil {
		return m[1], m[2] == ":" && m[4] == ":"
	}
	return rest, false
}

// Put the search root back in front of the paths the searcher printed. It
// ran with the root as its working directory (so that globs are
// root-relative), which makes every hit relative; the annotator and the
// agent both want a path they can open from anywhere.
func absolutizeGrepPath(l, root string) string {
	if l == "" || l == "--" || strings.HasPrefix(l, "/") {
		return l
	}
	// Plain concatenation, not filepath.Join: the rest of the line is
	// matched source text, and cleaning it would rewrite any "//" or
	// "/./" the code happens to contain.
	return strings.TrimSuffix(root, "/") + "/" + strings.TrimPrefix(l, "./")
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
func annotateGrepHits(ses session, lines []string, blame bool, kindFilter string) (drop map[int]bool, unclassified int) {
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
		// The path ends at the first "<sep><number><sep>" (grepHitPathRe),
		// and only a hit has ":" on both sides of the number; a context line
		// has "-". Splitting on the first two ":" instead would read a
		// context line whose text holds "12:30:00" or "foo.go:12:" as a hit
		// at a file that does not exist. The root is taken off before the
		// match, as grepHitPath does, so a "-7-" in the checkout's own path
		// cannot pass for a context line's separator.
		prefix, rel := "", l
		if ses.Root != "" && strings.HasPrefix(l, ses.Root+"/") {
			prefix, rel = ses.Root+"/", l[len(ses.Root)+1:]
		}
		m := grepHitPathRe.FindStringSubmatch(rel)
		if m == nil || m[2] != ":" || m[4] != ":" || m[1] == "" {
			continue
		}
		file := prefix + m[1]
		lineNo, err := strconv.Atoi(m[3])
		if err != nil || lineNo <= 0 {
			continue
		}
		rest := rel[len(m[0]):]
		// rg --column emits path:line:col:text; take the column if present.
		col := 0
		if p3 := strings.Index(rest, ":"); p3 > 0 {
			if n, err := strconv.Atoi(rest[:p3]); err == nil && n > 0 {
				col = n
				rest = rest[p3+1:]
			}
		}
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
	// Hits the classifier never saw cannot answer a kind= filter either
	// way; under a filter they go, and the caller is told how many.
	leaveUnclassified := func(files []string) {
		for _, file := range files {
			unclassified += len(byFile[file])
			for _, h := range byFile[file] {
				if kindFilter != "" {
					drop[h.idx] = true
					continue
				}
				// One shape for every hit in a reply. An annotated hit has
				// its raw column stripped, and an unannotated one used to
				// keep `path:line:col:text`, so a single reply carried two
				// formats and could not be parsed by one rule.
				lines[h.idx] = fmt.Sprintf("%s:%d:%s", file, h.line, h.rest)
			}
		}
	}
	for fi, file := range order {
		if fi >= maxFiles || annotated >= maxHits {
			leaveUnclassified(order[fi:])
			return drop, unclassified
		}
		var want, cols []any
		var lineNos []int
		for _, h := range byFile[file] {
			want = append(want, h.line)
			cols = append(cols, h.col)
			lineNos = append(lineNos, h.line)
		}
		res, err := nvimCall(ses.Socket, "enclosing_symbols",
			map[string]any{"file": file, "lines": want, "cols": cols})
		if err != nil {
			if editorUnreachable(err) {
				// Every further call would fail the same way; leave the
				// rest plain too.
				leaveUnclassified(order[fi:])
				return drop, unclassified
			}
			// This file only (gone since the search, no parser): the
			// others still get their turn.
			leaveUnclassified(order[fi : fi+1])
			continue
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

func runListFiles(ses session, args map[string]any) (string, error) {
	root := ses.Root
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
func callTool(name string, args map[string]any, ses session) (string, error) {
	root := ses.Root
	// "workspace" is a routing argument (see routing.go); the tool itself
	// has no use for it and the Lua side would only have to ignore it.
	if _, ok := args["workspace"]; ok {
		stripped := map[string]any{}
		for k, v := range args {
			if k != "workspace" {
				stripped[k] = v
			}
		}
		args = stripped
	}
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
		// Every tool that takes glob= expands it against args.root on the
		// Lua side (replace_pattern and unreferenced_symbols included), and
		// every edit tool needs it for its post-edit report.
		case "ts_query", "find_symbol", "workspace_map", "workspace_tree", "workspace_symbols", "install_language",
			"replace_symbol_body", "replace_symbol_lines", "insert_after_symbol", "insert_before_symbol", "insert_lines", "undo_edit", "rename_symbol", "check_project", "run_tests",
			"create_file", "move_file", "delete_file", "move_symbols", "replace_pattern", "unreferenced_symbols":
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
		if ses.Headless {
			// The server autosaves after edits; tools word their notes accordingly.
			resolved := map[string]any{}
			for k, v := range args {
				resolved[k] = v
			}
			resolved["headless"] = true
			args = resolved
		}
		result, err := nvimCall(ses.Socket, name, args)
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
					if crumb := readContext(ses, file, int(first)); crumb != "" {
						out = crumb + "\n" + out
					}
				}
			}
		}
		return out, nil
	}
	var out string
	var err error
	switch name {
	case "read_file":
		out, err = runReadFile(ses, args)
		if err == nil && os.Getenv("AGENT99_NO_LSP") == "" {
			// Let the editor's code window follow the read (best-effort).
			nvimCall(ses.Socket, "ui_follow", map[string]any{
				"file": resolveInRoot(root, args["path"]),
				"line": argInt(args, "offset", 1),
			})
		}
	case "grep":
		out, err = runGrep(ses, args)
	case "list_files":
		out, err = runListFiles(ses, args)
	default:
		return "", fmt.Errorf("unknown tool: %s", name)
	}
	if err != nil {
		return "", err
	}
	return out + verdictCarry(ses), nil
}

// verdictCarry fetches what the editor owes from earlier edits - verdicts
// deferred by wait=false, diagnostics that arrived after their report - so
// a reply produced outside the editor (grep, read_file, list_files) carries
// them too, as the editor's own replies do. Best-effort: with no editor to
// ask, or nothing owed, it adds nothing.
func verdictCarry(ses session) string {
	if ses.Socket == "" || os.Getenv("AGENT99_NO_LSP") != "" {
		return ""
	}
	result, err := nvimCall(ses.Socket, "verdict_carry", map[string]any{})
	if err != nil {
		return ""
	}
	m, ok := result.(map[string]any)
	if !ok || len(m) == 0 {
		return ""
	}
	text, err := renderJSON(m)
	if err != nil {
		return ""
	}
	return "\n\nfrom earlier edits:\n" + string(text)
}
