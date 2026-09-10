package main

// Which client a call belongs to.
//
// One agent99-bridge serves every agent that talks to it, and several of the
// records it keeps are per client rather than per project: the undo ledger,
// the check_project and run_tests baselines, and the set of diagnostics a
// client has already been shown. Keyed by root alone they leaked between
// clients - one agent's undo_edit() reverted another agent's edit and
// reported success, and a client that had never recorded a baseline was
// told how many lines were "new since the baseline" another client
// recorded. Every request now carries a client id, and the editor keys
// those records by (root, client).
//
// What the transport can actually tell us, measured against Claude Code
// 2.1.267 with a logging MCP server:
//
//   - one MCP connection is one server process, so a second Claude Code
//     session, a second T3 thread and an editor-embedded bridge are each a
//     different client, and are separated by this;
//   - the subagents of one session share that one connection. Their
//     tools/call requests carry _meta.claudecode/toolUseId, which is unique
//     per call, and progressToken, a per-connection counter - nothing that
//     groups one agent's calls together. The bridge cannot tell such agents
//     apart on its own. A harness that wants them separated sends
//     _meta["agent99/client"], which is honoured per request, or gives each
//     agent its own server process with AGENT99_CLIENT_ID set.
//
// Nothing here guesses. Where the id cannot tell two agents apart they
// share one ledger, as they did before, and the replies say whose entries
// they are rather than claiming an isolation that is not there.

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// The key a caller can set on a tools/call request to say which agent it is
// speaking for. MCP has no per-agent identity of its own; this is the one
// place a harness can supply one.
const clientMetaKey = "agent99/client"

var (
	processClientOnce sync.Once
	processClient     string
)

// processClientID is who this bridge process is, for calls that name no
// client of their own. Embedded in an editor it is the editor: the user's
// Neovim session and the agent run inside it are one client, and the
// interactive revert takes the same ledger the tools record into.
func processClientID() string {
	processClientOnce.Do(func() {
		switch {
		case embeddedMode():
			processClient = "editor"
		case os.Getenv("AGENT99_CLIENT_ID") != "":
			processClient = os.Getenv("AGENT99_CLIENT_ID")
		case os.Getenv("CLAUDE_CODE_SESSION_ID") != "":
			// The id the client's own transcript is filed under, so it is
			// stable across every server this session starts.
			processClient = os.Getenv("CLAUDE_CODE_SESSION_ID")
		default:
			processClient = "anon-" + randomID()
		}
	})
	return processClient
}

// metaClient reads the client id off a request's _meta, if it carries one.
func metaClient(params map[string]any) string {
	meta, _ := params["_meta"].(map[string]any)
	if meta == nil {
		return ""
	}
	id, _ := meta[clientMetaKey].(string)
	return strings.TrimSpace(id)
}

// callClient is the id one request is keyed by: what the request declared,
// else what this process is.
func callClient(declared string) string {
	if declared != "" {
		return declared
	}
	return processClientID()
}

// shortClient is the id as a reply names it. Client ids are opaque and a
// session id is a 36-character UUID, so replies carry a prefix; it is a
// label to tell holders apart in one sentence, not something to address a
// client by.
func shortClient(id string) string {
	if len(id) <= 12 {
		return id
	}
	return id[:8]
}

// Which clients are using a workspace. A client is counted from the first
// call served by that root, not only from an explicit open_workspace: an
// auto-opened or revived workspace holds the same shared editor state, and
// what the count is for is telling an agent that the ledger, the baselines
// and the buffers it is about to use are not its own alone.
var (
	holderMu sync.Mutex
	holders  = map[string]map[string]time.Time{}
)

func noteHolder(root, client string) {
	if root == "" || client == "" {
		return
	}
	holderMu.Lock()
	defer holderMu.Unlock()
	if holders[root] == nil {
		holders[root] = map[string]time.Time{}
	}
	holders[root][client] = time.Now()
}

// holdersOf lists the clients using a root, sorted, this one included.
func holdersOf(root string) []string {
	holderMu.Lock()
	defer holderMu.Unlock()
	out := make([]string, 0, len(holders[root]))
	for client := range holders[root] {
		out = append(out, client)
	}
	sort.Strings(out)
	return out
}

// otherHolders lists the clients using a root apart from this one.
func otherHolders(root, client string) []string {
	out := []string{}
	for _, held := range holdersOf(root) {
		if held != client {
			out = append(out, held)
		}
	}
	return out
}

// forgetHolders drops the roster for a workspace that is gone. The editor
// state it counted holders of went with it.
func forgetHolders(root string) {
	holderMu.Lock()
	defer holderMu.Unlock()
	delete(holders, root)
}

// sharedNote is the line a reply carries when other clients are using this
// workspace: what is shared, what is not, and that the number is a fact
// about right now rather than something to cache.
func sharedNote(root, client string) string {
	others := otherHolders(root, client)
	if len(others) == 0 {
		return ""
	}
	labels := make([]string, 0, len(others))
	for _, id := range others {
		labels = append(labels, shortClient(id))
	}
	return fmt.Sprintf("this workspace is shared: %d clients are using it, the others being %s. "+
		"One Neovim holds the buffers and the language servers for a root, so their edits "+
		"land in the same files as yours; the undo ledger, the check_project and run_tests "+
		"baselines and the diagnostics you have been shown are yours alone. A client can "+
		"join or leave between two of your calls, so this count is not yours to cache",
		len(others)+1, strings.Join(labels, ", "))
}
