package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

func TestWorkspaceIdleTimeout(t *testing.T) {
	cases := []struct {
		env  string
		want time.Duration
	}{
		{"", defaultWorkspaceIdle},
		{"45m", 45 * time.Minute},
		{"2h", 2 * time.Hour},
		{"0", 0},
		{"off", 0},
		{"OFF", 0},
		{"nonsense", defaultWorkspaceIdle},
		{"-5m", defaultWorkspaceIdle},
	}
	for _, test := range cases {
		t.Setenv("AGENT99_WORKSPACE_IDLE", test.env)
		if got := workspaceIdleTimeout(); got != test.want {
			t.Errorf("AGENT99_WORKSPACE_IDLE=%q: got %s, want %s", test.env, got, test.want)
		}
	}
}

// deadPid returns the pid of a process that has certainly exited.
func deadPid(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("true")
	if err := cmd.Run(); err != nil {
		t.Skipf("cannot run a throwaway process: %v", err)
	}
	return cmd.Process.Pid
}

func TestSweepStaleSocketsLeavesLiveOnesAlone(t *testing.T) {
	runtime := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", runtime)
	dir, err := socketDir()
	if err != nil {
		t.Fatal(err)
	}

	gone := deadPid(t)
	if processAlive(gone) {
		t.Skip("the throwaway pid was reused; nothing to assert against")
	}
	files := map[string]bool{ // name -> should survive the sweep
		"aaaa11-" + strconv.Itoa(os.Getpid()) + ".sock": true,  // this bridge's own
		"bbbb22-" + strconv.Itoa(gone) + ".sock":        false, // a bridge that is gone
		"cccc33.sock":                                   true,  // no pid in the name
		"notes.txt":                                     true,  // not a socket at all
	}
	for name := range files {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	sweepStaleSockets()

	for name, wantKept := range files {
		_, err := os.Stat(filepath.Join(dir, name))
		if kept := err == nil; kept != wantKept {
			verb := "was removed"
			if kept {
				verb = "survived"
			}
			t.Errorf("%s %s, expected the opposite", name, verb)
		}
	}
}

func TestReopenableBookkeeping(t *testing.T) {
	headlessMu.Lock()
	for root := range reopenable {
		delete(reopenable, root)
	}
	headlessMu.Unlock()
	t.Cleanup(func() {
		headlessMu.Lock()
		for root := range reopenable {
			delete(reopenable, root)
		}
		headlessMu.Unlock()
	})

	headlessMu.Lock()
	noteReopenableLocked("/tmp/one", "test")
	noteReopenableLocked("", "test")
	headlessMu.Unlock()

	roots := reopenableRoots()
	if len(roots) != 1 || roots[0] != "/tmp/one" {
		t.Fatalf("expected only /tmp/one to be reopenable, got %v", roots)
	}

	// A path inside a vanished root is what triggers a revival; a path
	// outside every one of them must not.
	if reviveFor("/tmp/elsewhere/file.go") != nil {
		t.Error("revived a workspace for a path belonging to no reopenable root")
	}

	headlessMu.Lock()
	forgetReopenableLocked("/tmp/one")
	headlessMu.Unlock()
	if roots := reopenableRoots(); len(roots) != 0 {
		t.Errorf("root still reopenable after being forgotten: %v", roots)
	}
}

// TestRelativeRevivalRoot covers the gap issue #1 reported: a call that
// names only a relative path (create_file, find_symbol, hover... after
// argPaths has already dropped it) still needs a way to pick one workspace
// out of several reopenable roots, or it falls through to a dead end.
func TestRelativeRevivalRoot(t *testing.T) {
	a := t.TempDir()
	b := t.TempDir()
	if err := os.MkdirAll(filepath.Join(a, "roles/fleet_ssh/tasks"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(a, "roles/fleet_ssh/tasks/existing.yml"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(b, "roles/nebula/tasks"), 0o755); err != nil {
		t.Fatal(err)
	}

	roots := []string{a, b}
	if got := relativeRevivalRoot("roles/fleet_ssh/tasks/existing.yml", roots); got != a {
		t.Errorf("existing file: got %q, want %q", got, a)
	}
	if got := relativeRevivalRoot("roles/fleet_ssh/tasks/new.yml", roots); got != a {
		t.Errorf("new file in an existing directory: got %q, want %q", got, a)
	}
	if got := relativeRevivalRoot("roles/nebula/tasks/new.yml", roots); got != b {
		t.Errorf("new file under the other root: got %q, want %q", got, b)
	}
	if got := relativeRevivalRoot("nowhere/at/all.yml", roots); got != "" {
		t.Errorf("path under neither root: got %q, want \"\"", got)
	}
	if got := relativeRevivalRoot("README.md", roots); got != "" {
		t.Errorf("bare filename with no directory to disambiguate: got %q, want \"\"", got)
	}
}
