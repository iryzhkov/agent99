package main

// The agent loop for OpenAI-compatible chat-completions APIs (DeepSeek by
// default). Reads a JSON payload on stdin, loops over tool calls, prints
// the model's final text answer on stdout. Loop hygiene: identical tool
// calls are never re-executed (the model gets a pointed nudge instead), and
// after two stalled rounds - or on the last round - tools are disabled so
// the model must answer.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"
)

const (
	httpTimeout      = 300 * time.Second
	defaultBaseURL   = "https://api.deepseek.com/v1"
	defaultModel     = "deepseek-chat"
	defaultKeyEnv    = "DEEPSEEK_API_KEY"
	defaultMaxRounds = 30
)

const systemPrompt = "You are a precise, headless code-editing agent embedded in the user's " +
	"Neovim session. You gather context with your tools, then produce exactly " +
	"the output the task asks for. You never invent APIs: when unsure about a " +
	"signature or behavior, check it with the LSP tools (hover, definition, " +
	"references) or read the code. Your final message is inserted into a file " +
	"verbatim, so it must contain only the requested replacement text - no " +
	"markdown fences, no explanation."

type payload struct {
	Prompt        string           `json:"prompt"`
	Root          string           `json:"root"`
	BaseURL       string           `json:"base_url"`
	Model         string           `json:"model"`
	APIKeyEnv     string           `json:"api_key_env"`
	MaxRounds     int              `json:"max_rounds"`
	Messages      []map[string]any `json:"messages"`
	TranscriptOut string           `json:"transcript_out"`
	FinalReminder string           `json:"final_reminder"`
	FullTools     bool             `json:"full_tools"`
	System        string           `json:"system"`
	Stream        bool             `json:"stream"`
}

type toolCall struct {
	ID       string `json:"id"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"`
	} `json:"function"`
}

func openaiTools(full bool) []map[string]any {
	// AGENT99_NO_LSP=1 strips the editor-backed tools, leaving only plain
	// file access. Exists for A/B-measuring what the LSP tools contribute.
	all := append(append([]tool{}, activeTools(lspTools, full)...), fileTools...)
	if os.Getenv("AGENT99_NO_LSP") != "" {
		all = append([]tool{}, fileTools...)
	}
	var out []map[string]any
	for _, t := range all {
		out = append(out, map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":        t.Name,
				"description": t.Description,
				"parameters":  t.InputSchema,
			},
		})
	}
	return out
}

func chat(client *http.Client, baseURL, apiKey string, body map[string]any) (map[string]any, error) {
	data, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	url := strings.TrimRight(baseURL, "/") + "/chat/completions"
	req, err := http.NewRequest("POST", url, bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+apiKey)
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 32*1024*1024))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		detail := string(raw)
		if len(detail) > 2000 {
			detail = detail[:2000]
		}
		return nil, fmt.Errorf("API error %d from %s: %s", resp.StatusCode, url, detail)
	}
	var parsed map[string]any
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil, fmt.Errorf("unparseable API response: %v", err)
	}
	return parsed, nil
}

// chatStream runs one SSE round: content deltas go to stdout immediately
// (the editor renders them live), tool-call deltas are assembled per index.
// Returns the reconstructed assistant message and the usage object.
func chatStream(client *http.Client, baseURL, apiKey string, body map[string]any) (map[string]any, map[string]any, error) {
	body["stream"] = true
	body["stream_options"] = map[string]any{"include_usage": true}
	data, err := json.Marshal(body)
	if err != nil {
		return nil, nil, err
	}
	url := strings.TrimRight(baseURL, "/") + "/chat/completions"
	req, err := http.NewRequest("POST", url, bytes.NewReader(data))
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Accept", "text/event-stream")
	resp, err := client.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 2000))
		return nil, nil, fmt.Errorf("API error %d from %s: %s", resp.StatusCode, url, raw)
	}
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 64*1024), 8*1024*1024)
	var content strings.Builder
	type tcAcc struct {
		id, name string
		args     strings.Builder
	}
	calls := map[int]*tcAcc{}
	maxIdx := -1
	var usage map[string]any
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		payload := strings.TrimSpace(line[5:])
		if payload == "[DONE]" {
			break
		}
		var chunk map[string]any
		if json.Unmarshal([]byte(payload), &chunk) != nil {
			continue
		}
		if u, ok := chunk["usage"].(map[string]any); ok && u != nil {
			usage = u
		}
		choices, _ := chunk["choices"].([]any)
		if len(choices) == 0 {
			continue
		}
		choice, _ := choices[0].(map[string]any)
		delta, _ := choice["delta"].(map[string]any)
		if delta == nil {
			continue
		}
		if c, ok := delta["content"].(string); ok && c != "" {
			content.WriteString(c)
			fmt.Print(c) // os.Stdout is unbuffered: the editor sees it live
		}
		if tcs, ok := delta["tool_calls"].([]any); ok {
			for _, t := range tcs {
				tc, _ := t.(map[string]any)
				if tc == nil {
					continue
				}
				idx := 0
				if f, ok := tc["index"].(float64); ok {
					idx = int(f)
				}
				if calls[idx] == nil {
					calls[idx] = &tcAcc{}
					if idx > maxIdx {
						maxIdx = idx
					}
				}
				if id, ok := tc["id"].(string); ok {
					calls[idx].id += id
				}
				if fn, ok := tc["function"].(map[string]any); ok {
					if n, ok := fn["name"].(string); ok {
						calls[idx].name += n
					}
					if a, ok := fn["arguments"].(string); ok {
						calls[idx].args.WriteString(a)
					}
				}
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, nil, fmt.Errorf("stream read failed: %v", err)
	}
	msg := map[string]any{"role": "assistant", "content": content.String()}
	if maxIdx >= 0 {
		var list []any
		for i := 0; i <= maxIdx; i++ {
			if c := calls[i]; c != nil {
				list = append(list, map[string]any{
					"id":   c.id,
					"type": "function",
					"function": map[string]any{
						"name":      c.name,
						"arguments": c.args.String(),
					},
				})
			}
		}
		msg["tool_calls"] = list
	}
	return msg, usage, nil
}

// canonicalKey builds a stable identity for a tool call so repeats can be
// detected regardless of JSON key order.
// After one of these runs, buffers have changed: earlier tool results are
// stale and re-issuing a previously-seen call is legitimate, so the
// repeat-call guard must forget its history.
var stateChangingTools = map[string]bool{
	"apply_code_action":    true,
	"replace_symbol_body":  true,
	"replace_symbol_lines": true,
	"insert_after_symbol":  true,
	"insert_before_symbol": true,
}

func canonicalKey(name, arguments string) (string, map[string]any, bool) {
	args := map[string]any{}
	if strings.TrimSpace(arguments) != "" {
		if err := json.Unmarshal([]byte(arguments), &args); err != nil {
			return "", nil, false
		}
	}
	keys := make([]string, 0, len(args))
	for k := range args {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString(name)
	for _, k := range keys {
		v, _ := json.Marshal(args[k])
		fmt.Fprintf(&b, "|%s=%s", k, v)
	}
	return b.String(), args, true
}

// A degenerate reply repeats the same long line over and over (an observed
// deepseek-chat failure mode at temperature 0). Detected when one line of
// 30+ chars appears 4+ times and makes up at least half of all long lines.
func isDegenerate(s string) bool {
	if len(s) < 400 {
		return false
	}
	counts := map[string]int{}
	total := 0
	for _, line := range strings.Split(s, "\n") {
		l := strings.TrimSpace(line)
		if len(l) < 30 {
			continue
		}
		counts[l]++
		total++
	}
	for _, c := range counts {
		if c >= 4 && c*2 >= total {
			return true
		}
	}
	return false
}

func saveTranscript(path string, messages []map[string]any) {
	if path == "" {
		return
	}
	data, err := json.MarshalIndent(messages, "", " ")
	if err != nil {
		return
	}
	_ = os.WriteFile(path, data, 0o600)
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "agent99_agent: "+format+"\n", a...)
	os.Exit(1)
}

func runAgent() {
	var p payload
	if err := json.NewDecoder(os.Stdin).Decode(&p); err != nil {
		fail("bad payload on stdin: %v", err)
	}
	if p.BaseURL == "" {
		p.BaseURL = defaultBaseURL
	}
	if p.Model == "" {
		p.Model = defaultModel
	}
	if p.APIKeyEnv == "" {
		p.APIKeyEnv = defaultKeyEnv
	}
	if p.MaxRounds <= 0 {
		p.MaxRounds = defaultMaxRounds
	}
	apiKey := os.Getenv(p.APIKeyEnv)
	if apiKey == "" {
		fmt.Fprintf(os.Stderr, "agent99_agent: environment variable %s is not set\n", p.APIKeyEnv)
		os.Exit(2)
	}

	var messages []map[string]any
	if len(p.Messages) > 0 {
		// Continuing a previous conversation: the prior transcript already
		// carries the system prompt; the new prompt is a follow-up turn.
		messages = append(messages, p.Messages...)
		messages = append(messages, map[string]any{"role": "user", "content": p.Prompt})
	} else {
		system := systemPrompt
		if p.System != "" {
			system = p.System
		}
		messages = []map[string]any{
			{"role": "system", "content": system},
			{"role": "user", "content": p.Prompt},
		}
	}

	client := &http.Client{Timeout: httpTimeout}
	tools := openaiTools(p.FullTools)
	seenCalls := map[string]int{}
	stalledRounds := 0
	degenerateRetried := false
	forceFinal := false

	for round := 0; round < p.MaxRounds; round++ {
		body := map[string]any{
			"model":       p.Model,
			"messages":    messages,
			"tools":       tools,
			"temperature": 0.0,
		}
		if forceFinal {
			forceFinal = false
			body["tool_choice"] = "none"
		}
		// Break degenerate loops: after two rounds of only repeated tool
		// calls, or on the last round, forbid tools so the model must answer.
		if stalledRounds >= 2 || round == p.MaxRounds-1 {
			body["tool_choice"] = "none"
			nudge := "Stop calling tools. You have all the information you are going " +
				"to get. Produce your final answer now, in the exact format the " +
				"task requires."
			if p.FinalReminder != "" {
				nudge += " " + p.FinalReminder
			}
			messages = append(messages, map[string]any{"role": "user", "content": nudge})
			body["messages"] = messages
		}

		var msg, usage map[string]any
		if p.Stream {
			var err error
			msg, usage, err = chatStream(client, p.BaseURL, apiKey, body)
			if err != nil {
				fail("%v", err)
			}
		} else {
			resp, err := chat(client, p.BaseURL, apiKey, body)
			if err != nil {
				fail("%v", err)
			}
			usage, _ = resp["usage"].(map[string]any)
			choices, _ := resp["choices"].([]any)
			if len(choices) == 0 {
				fail("API response had no choices")
			}
			choice, _ := choices[0].(map[string]any)
			msg, _ = choice["message"].(map[string]any)
		}
		if usage != nil {
			fmt.Fprintf(os.Stderr, "usage: prompt=%v (cache_hit=%v) completion=%v\n",
				usage["prompt_tokens"], usage["prompt_cache_hit_tokens"], usage["completion_tokens"])
		}

		// Typed view of the tool calls, generic view for replay.
		var calls []toolCall
		if rawCalls, err := json.Marshal(msg["tool_calls"]); err == nil {
			_ = json.Unmarshal(rawCalls, &calls)
		}

		if len(calls) == 0 {
			content, _ := msg["content"].(string)
			content = strings.TrimSpace(content)
			messages = append(messages, map[string]any{"role": "assistant", "content": content})
			if !degenerateRetried && isDegenerate(content) {
				// One clean retry with tools disabled; if it degenerates
				// again we accept it rather than loop.
				degenerateRetried = true
				forceFinal = true
				fmt.Fprintln(os.Stderr, "degenerate reply detected -> retrying once")
				retry := "Your previous reply degenerated into repetition and was discarded. " +
					"Give your final answer now: concise, complete, no repeated sentences."
				if p.FinalReminder != "" {
					retry += " " + p.FinalReminder
				}
				messages = append(messages, map[string]any{"role": "user", "content": retry})
				continue
			}
			saveTranscript(p.TranscriptOut, messages)
			if content == "" {
				fail("model returned an empty reply")
			}
			if p.Stream {
				fmt.Println() // content already went out as deltas
			} else {
				fmt.Println(content)
			}
			return
		}

		messages = append(messages, msg)
		freshCalls := 0
		for _, tc := range calls {
			name := tc.Function.Name
			key, args, keyOK := canonicalKey(name, tc.Function.Arguments)
			var result string
			if keyOK && seenCalls[key] > 0 {
				// Identical call already made this run: don't re-execute,
				// push back instead. Repetition here is always a stuck loop.
				seenCalls[key]++
				result = fmt.Sprintf(
					"You already called %s with these exact arguments (%d times); the "+
						"result has not changed and is above in the conversation. Do not "+
						"repeat tool calls. If you have enough information, produce your "+
						"final answer now in the required format.", name, seenCalls[key])
				fmt.Fprintf(os.Stderr, "tool %s REPEATED -> nudged\n", name)
			} else {
				if keyOK {
					seenCalls[key] = 1
				}
				freshCalls++
				out, err := callTool(name, args, p.Root)
				if err == nil && stateChangingTools[name] {
					seenCalls = map[string]int{}
				}
				if err != nil {
					result = fmt.Sprintf("Error: %v", err)
				} else {
					result = out
				}
				if len(result) > maxToolOutputChars {
					result = result[:maxToolOutputChars] + "\n... (output truncated)"
				}
				fmt.Fprintf(os.Stderr, "tool %s(%s) -> %d chars\n",
					name, tc.Function.Arguments, len(result))
			}
			messages = append(messages, map[string]any{
				"role":         "tool",
				"tool_call_id": tc.ID,
				"content":      result,
			})
		}
		if freshCalls == 0 {
			stalledRounds++
		} else {
			stalledRounds = 0
		}
	}

	saveTranscript(p.TranscriptOut, messages)
	fail("gave up after %d rounds without a final answer", p.MaxRounds)
}
