package main

import (
	"strings"
	"testing"
)

func TestDedupeToolResult(t *testing.T) {
	seen := map[string]int{}
	big := strings.Repeat("lua/agent99/lsp.lua:1281 [enclosing_symbols @12/23]: pos = n - e.first\n", 20)

	if out, suppressed := dedupeToolResult(seen, 1, "grep", big); suppressed || out != big {
		t.Error("first occurrence must pass through untouched")
	}
	out, suppressed := dedupeToolResult(seen, 2, "grep", big)
	if !suppressed {
		t.Error("identical second result not suppressed")
	}
	if !strings.Contains(out, "call #1") || strings.Contains(out, "e.first") {
		t.Errorf("replacement should cite the first call and drop the content, got: %s", out)
	}
	if _, suppressed := dedupeToolResult(seen, 3, "grep", big+"x"); suppressed {
		t.Error("different result wrongly suppressed")
	}
	small := "(no matches)"
	if _, s1 := dedupeToolResult(seen, 4, "grep", small); s1 {
		t.Error("small result must never be suppressed")
	}
	if _, s2 := dedupeToolResult(seen, 5, "grep", small); s2 {
		t.Error("small duplicate must never be suppressed")
	}
}

func TestIsDegenerate(t *testing.T) {
	repeated := strings.Repeat(
		"Let me check the finish_failed function and other places where fields are written.\n\n", 10)
	if !isDegenerate(repeated) {
		t.Error("repeated paragraph not flagged as degenerate")
	}
	normal := "The fields are:\n- id\n- time\n- file\n- first\n- last\n- instruction\n" +
		"- provider\n- transcript\n- status\n- result\n- rounds\n- tokens_in\n- tokens_out\n" +
		"Each of these is written in a different place in init.lua, and the record is " +
		"persisted after every change so the history stays consistent across requests."
	if isDegenerate(normal) {
		t.Error("normal answer wrongly flagged as degenerate")
	}
	code := "<replacement>\nlocal out = {}\nfor _, item in ipairs(list) do\n" +
		"    out[#out + 1] = item\nend\nreturn table.concat(out, \"\\n\")\n</replacement>"
	if isDegenerate(code) {
		t.Error("code reply wrongly flagged as degenerate")
	}
	short := "yes"
	if isDegenerate(short) {
		t.Error("short reply wrongly flagged")
	}
}
