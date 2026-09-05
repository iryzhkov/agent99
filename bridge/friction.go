package main

// Friction spool: one JSON line per MCP tool call, appended to a file under
// the local data directory, so that a later pass can measure which tools
// error, which errors recur, and which calls an agent has to retry or give
// up on. It is the passive half of the tool-feedback loop: asking an agent
// at the end of a session how a tool felt produces a fluent answer, but a
// partly invented one, while the spool records what actually happened.
//
// The spool is deliberately thin. It records the shape of a call - the tool,
// which argument keys were present, whether it succeeded, how long it took -
// and never argument values or replies, because those carry the source code
// the agent is working on. Error messages are folded into a class first:
// paths, quoted text and numbers become placeholders, which both drops the
// content and turns "lines 11-11 of /tmp/a99t/T.qml do not hold the expected
// text" into a fingerprint that groups with every other occurrence of the
// same failure.
//
// Writing to the spool must never affect a tool call, so every failure in
// here is dropped in silence: losing an event is better than failing a call
// because the disk is full.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime/debug"
	"sort"
	"strings"
	"sync"
	"time"
)

// frictionSource names this tool's directory in the spool. Every tool that
// writes the spool has its own, so one report can rank them side by side.
const frictionSource = "agent99"

// frictionEvent is one line of the spool.
type frictionEvent struct {
	TS      string   `json:"ts"`
	Host    string   `json:"host"`
	Session string   `json:"session"`
	Proc    string   `json:"proc"`
	Client  string   `json:"client,omitempty"`
	Ver     string   `json:"ver,omitempty"`
	Seq     int      `json:"seq"`
	Tool    string   `json:"tool"`
	Root    string   `json:"root,omitempty"`
	Rev     string   `json:"rev,omitempty"`
	Args    []string `json:"args,omitempty"`
	OK      bool     `json:"ok"`
	Err     string   `json:"err,omitempty"`
	Ms      int64    `json:"ms"`
}

var (
	frictionMu     sync.Mutex
	frictionSeq    int
	frictionClient string
	frictionOnce   sync.Once
	frictionSess   string
	frictionProc   string
	frictionVer    string
	frictionHost   string

	revMu    sync.Mutex
	revCache = map[string]string{}
)

// frictionEnabled reports whether calls are spooled. Off unless someone asked
// for it, because this is a shared tool and nobody else's editing should start
// producing a record of itself because they installed a plugin. Turning it on
// is a deliberate act: create the file `enabled` in the spool directory, or set
// AGENT99_FRICTION=1 (TOOLFEEDBACK=1 does the same for every tool that writes
// this spool). Either way the spool is a file on the local machine and nothing
// transmits it anywhere; collecting it is a separate, equally deliberate step.
func frictionEnabled() bool {
	switch os.Getenv("AGENT99_FRICTION") {
	case "1":
		return true
	case "0":
		return false
	}
	switch os.Getenv("TOOLFEEDBACK") {
	case "1":
		return true
	case "0":
		return false
	}
	dir := frictionDir()
	if dir == "" {
		return false
	}
	_, err := os.Stat(filepath.Join(dir, "enabled"))
	return err == nil
}

// frictionDir is where the spool files live, one per host per day.
func frictionDir() string {
	// AGENT99_FRICTION_DIR first, then the name the other tools writing this
	// spool use, so one setting moves all of them together.
	for _, name := range []string{"AGENT99_FRICTION_DIR", "TOOLFEEDBACK_DIR"} {
		if dir := os.Getenv(name); dir != "" {
			return dir
		}
	}
	if dir := os.Getenv("XDG_DATA_HOME"); dir != "" {
		return filepath.Join(dir, "toolfeedback")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".local", "share", "toolfeedback")
}

// frictionIdent fills in the identity fields shared by every event of this
// process. The session id is the one Claude Code exports to its MCP servers,
// which is the same id its transcript is filed under - that is what lets a
// later pass line a spooled error up with what the agent did next. Without
// it (another client, or a bare `agent99-bridge mcp`) a random id at least
// keeps one process's calls together.
func frictionIdent() {
	frictionOnce.Do(func() {
		frictionSess = os.Getenv("CLAUDE_CODE_SESSION_ID")
		if frictionSess == "" {
			frictionSess = "anon-" + randomID()
		}
		// One session can have several servers running at once, each with its
		// own sequence counter. Without something to tell them apart their
		// calls interleave into an order that never happened.
		frictionProc = randomID()
		frictionVer = buildVersion()
		frictionHost, _ = os.Hostname()
		if i := strings.IndexByte(frictionHost, '.'); i > 0 {
			frictionHost = frictionHost[:i]
		}
	})
}

func randomID() string {
	buf := make([]byte, 6)
	if _, err := rand.Read(buf); err != nil {
		return "unknown"
	}
	return hex.EncodeToString(buf)
}

// buildVersion is which build of the bridge made a call, so that a failure
// rate before a fix can be compared with the rate after it. Go records the
// commit in the binary when it is built inside a repository; the declared
// version is the fallback for a build made from a tarball.
func buildVersion() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return serverVersion
	}
	revision, modified := "", false
	for _, setting := range info.Settings {
		switch setting.Key {
		case "vcs.revision":
			revision = setting.Value
		case "vcs.modified":
			modified = setting.Value == "true"
		}
	}
	if revision == "" {
		return serverVersion
	}
	if len(revision) > 12 {
		revision = revision[:12]
	}
	if modified {
		revision += "+dirty"
	}
	return serverVersion + "/" + revision
}

// noteFrictionClient records who is on the other end of the connection, from
// the clientInfo of the initialize handshake. Which client made a call is
// worth knowing: the same tool is used differently by different harnesses.
func noteFrictionClient(params map[string]any) {
	info, _ := params["clientInfo"].(map[string]any)
	if info == nil {
		return
	}
	name, _ := info["name"].(string)
	version, _ := info["version"].(string)
	switch {
	case name != "" && version != "":
		frictionClient = name + "/" + version
	case name != "":
		frictionClient = name
	}
}

var (
	// Relative paths count too: an error naming agent99/bridge/mcp.go has to
	// fold the same way as one naming /home/igor/src/x.go, or the same failure
	// splits into a cluster per file.
	frictionPathRe  = regexp.MustCompile(`(?:[A-Za-z]:)?[\w.~@+-]*(?:/[\w.~@+-]+)+`)
	frictionFileRe  = regexp.MustCompile(`\b[\w-]{2,}\.[A-Za-z]{1,5}\b`)
	frictionQuoteRe = regexp.MustCompile(`"[^"]*"|'[^']*'`)
	frictionNumRe   = regexp.MustCompile(`\d+`)
	frictionSpaceRe = regexp.MustCompile(`\s+`)
)

// errClass folds an error message into a fingerprint: the first line, with
// paths, quoted text and numbers replaced by placeholders. Two calls that
// failed the same way for different files produce the same class, which is
// what makes counting them meaningful.
func errClass(text string) string {
	line := text
	if i := strings.IndexByte(line, '\n'); i >= 0 {
		line = line[:i]
	}
	line = strings.TrimPrefix(line, "Error: ")
	line = frictionPathRe.ReplaceAllString(line, "<path>")
	line = frictionFileRe.ReplaceAllString(line, "<path>")
	line = frictionQuoteRe.ReplaceAllString(line, "<str>")
	line = frictionNumRe.ReplaceAllString(line, "<n>")
	line = strings.TrimSpace(frictionSpaceRe.ReplaceAllString(line, " "))
	if len(line) > 160 {
		line = line[:160]
	}
	return line
}

// argKeys is the sorted set of argument names a call carried. The names are
// the part worth keeping: they say which way of addressing the code the
// agent reached for (match= or line numbers, glob or file, kind= or not).
func argKeys(args map[string]any) []string {
	if len(args) == 0 {
		return nil
	}
	keys := make([]string, 0, len(args))
	for k := range args {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if len(keys) > 24 {
		keys = keys[:24]
	}
	return keys
}

// resultText pulls the text out of an MCP tool result, which is where both
// a reply and an error message live.
func resultText(res map[string]any) string {
	content, ok := res["content"].([]map[string]any)
	if !ok || len(content) == 0 {
		return ""
	}
	text, _ := content[0]["text"].(string)
	return text
}

// workspaceRev is the commit a workspace was sitting on, with a marker when
// the tree had uncommitted changes. It is what turns a spooled failure into
// something that can be looked at again: the transcript says which call was
// made, and this says which state of the code it was made against. Computed
// once per root per process, because `git status` on a large tree is not
// something to run on every call, and because the answer only has to be true
// of the session rather than of the instant.
func workspaceRev(root string) string {
	if root == "" {
		return ""
	}
	revMu.Lock()
	defer revMu.Unlock()
	if rev, ok := revCache[root]; ok {
		return rev
	}
	rev := gitRev(root)
	revCache[root] = rev
	return rev
}

func gitRev(root string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "git", "-C", root, "rev-parse", "--short", "HEAD").Output()
	if err != nil {
		return "" // not a repository, or git is not installed
	}
	rev := strings.TrimSpace(string(out))
	if rev == "" {
		return ""
	}
	dirty, err := exec.CommandContext(ctx, "git", "-C", root, "status", "--porcelain").Output()
	if err == nil && len(strings.TrimSpace(string(dirty))) > 0 {
		rev += "+dirty"
	}
	return rev
}

// logFriction appends one event for a finished call. root is the workspace
// that answered, empty when the call never got that far.
func logFriction(name, root string, args, res map[string]any, started time.Time) {
	if !frictionEnabled() {
		return
	}
	frictionIdent()
	isError, _ := res["isError"].(bool)

	frictionMu.Lock()
	frictionSeq++
	ev := frictionEvent{
		TS:      time.Now().UTC().Format("2006-01-02T15:04:05.000Z"),
		Host:    frictionHost,
		Session: frictionSess,
		Proc:    frictionProc,
		Client:  frictionClient,
		Ver:     frictionVer,
		Seq:     frictionSeq,
		Tool:    name,
		Args:    argKeys(args),
		OK:      !isError,
		Ms:      time.Since(started).Milliseconds(),
	}
	frictionMu.Unlock()

	// Only the last element of the root: which project a call ran in is
	// worth knowing, the rest of the path is not the spool's business.
	if root != "" {
		ev.Root = filepath.Base(root)
		ev.Rev = workspaceRev(root)
	}
	if isError {
		ev.Err = errClass(resultText(res))
	}
	writeFriction(ev)
}

func writeFriction(ev frictionEvent) {
	dir := frictionDir()
	if dir == "" {
		return
	}
	line, err := json.Marshal(ev)
	if err != nil || len(line) > 8192 {
		return
	}
	host := ev.Host
	if host == "" {
		host = "unknown"
	}
	// One directory per tool, because a host name contains hyphens and so does
	// a tool name: with both in one file name there is no way to tell where the
	// first ends and the second begins.
	dir = filepath.Join(dir, frictionSource)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return
	}
	path := filepath.Join(dir, host+"-"+time.Now().UTC().Format("2006-01-02")+".jsonl")

	// One O_APPEND write of a short line, so several servers spooling at
	// once interleave whole lines rather than fragments.
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	f.Write(append(line, '\n'))
	f.Close()
}
