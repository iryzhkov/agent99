package main

import "testing"

// ripgrep gives up on a file holding a NUL byte after its first match and
// says so on stdout, among the results. Left there the line reads as a hit,
// while the rest of that file went unsearched: a TypeScript source file with
// one stray NUL was searched to its 94kth byte and no further, silently.
func TestBinaryStopPathFindsTheFileTheSearchGaveUpOn(t *testing.T) {
	cases := []struct {
		line string
		want string
	}{
		{
			line: `apps/web/src/ChatComposer.tsx: WARNING: stopped searching binary file after match (found "\0" byte around offset 94777)`,
			want: "apps/web/src/ChatComposer.tsx",
		},
		{
			line: `assets/blob.bin: binary file matches (found "\0" byte around offset 12)`,
			want: "assets/blob.bin",
		},
		{line: "src/main.go:12:4:\tresolvedTheme := theme()", want: ""},
		// A hit whose own text quotes the warning is still a hit.
		{line: `docs/notes.md:3:2:  rg says: WARNING: stopped searching binary file after match`, want: ""},
		{line: "", want: ""},
	}
	for _, c := range cases {
		if got := binaryStopPath(c.line); got != c.want {
			t.Errorf("binaryStopPath(%q) = %q, want %q", c.line, got, c.want)
		}
	}
}
