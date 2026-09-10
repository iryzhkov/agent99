package main

import (
	"strings"
	"testing"
)

func TestMetaClientReadsTheIdOffTheRequest(t *testing.T) {
	params := map[string]any{
		"name": "undo_edit",
		"_meta": map[string]any{
			"claudecode/toolUseId": "toolu_01",
			clientMetaKey:          "  agent-b  ",
		},
	}
	if got := metaClient(params); got != "agent-b" {
		t.Fatalf("metaClient = %q, want agent-b", got)
	}
	if got := metaClient(map[string]any{"name": "undo_edit"}); got != "" {
		t.Fatalf("metaClient with no _meta = %q, want empty", got)
	}
	// Only the key this server documents. The ids Claude Code does send are
	// per call (toolUseId) or per connection (progressToken), and neither
	// groups one agent's calls together.
	only := map[string]any{"_meta": map[string]any{"claudecode/toolUseId": "toolu_02"}}
	if got := metaClient(only); got != "" {
		t.Fatalf("metaClient off a toolUseId = %q, want empty", got)
	}
}

func TestCallClientPrefersWhatTheRequestDeclared(t *testing.T) {
	if got := callClient("agent-a"); got != "agent-a" {
		t.Fatalf("callClient(declared) = %q", got)
	}
	if got := callClient(""); got != processClientID() {
		t.Fatalf("callClient(\"\") = %q, want the process id %q", got, processClientID())
	}
}

func TestHolderRosterCountsTheClientsUsingARoot(t *testing.T) {
	root := "/tmp/agent99-holder-test"
	forgetHolders(root)
	defer forgetHolders(root)

	noteHolder(root, "agent-a")
	if note := sharedNote(root, "agent-a"); note != "" {
		t.Fatalf("one holder should say nothing about sharing, got %q", note)
	}
	noteHolder(root, "agent-b")
	if got := holdersOf(root); len(got) != 2 {
		t.Fatalf("holdersOf = %v, want two", got)
	}
	if got := otherHolders(root, "agent-b"); len(got) != 1 || got[0] != "agent-a" {
		t.Fatalf("otherHolders = %v, want [agent-a]", got)
	}
	note := sharedNote(root, "agent-b")
	// The wording is the point: a count alone left an agent to guess what
	// sharing an instance costs it.
	for _, want := range []string{"2 clients are using it", "agent-a",
		"the undo ledger", "yours alone", "not yours to cache"} {
		if !strings.Contains(note, want) {
			t.Fatalf("shared note %q does not mention %q", note, want)
		}
	}
	forgetHolders(root)
	if got := holdersOf(root); len(got) != 0 {
		t.Fatalf("holdersOf after forgetting = %v, want none", got)
	}
}

func TestShortClientKeepsAShortIdWhole(t *testing.T) {
	if got := shortClient("editor"); got != "editor" {
		t.Fatalf("shortClient(editor) = %q", got)
	}
	long := "e3fc0dab-362b-445f-90c7-b26fc55d7b71"
	if got := shortClient(long); got != "e3fc0dab" {
		t.Fatalf("shortClient(session id) = %q, want its first 8 characters", got)
	}
}
