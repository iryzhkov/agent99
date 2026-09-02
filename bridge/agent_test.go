package main

import (
	"strings"
	"testing"
)

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
