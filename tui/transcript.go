package main

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// What an agent is doing, read from its Claude Code session transcript
// (~/.claude/projects/*/<session>.jsonl): whether it is working, waiting on a
// tool, or done and at its prompt; what it was asked and last said; its tool
// calls over the last hour; and the messages it traded with other Claude
// sessions, which never touch the bus. Read-only, and only the file's tail.

const (
	tailBytes   = 2 << 20
	stripBins   = 30 // activity strip: 30 bins of 2 minutes
	stripSecs   = 120
	stateWork   = "working"
	stateTool   = "tool pending"
	stateDone   = "at its prompt"
	stateQuiet  = "quiet"
	trackEdit   = 0
	trackRead   = 1
	trackBash   = 2
	trackTalk   = 3
	trackCount  = 4
	pendingSlow = 45 // seconds a tool may run before we say it may be waiting on you
)

var trackNames = [trackCount]string{"edit", "read", "bash", "talk"}

type tEvent struct {
	Epoch int64
	Kind  string // asked, said, tool, msg-in, msg-out
	Who   string // the other session, for messages
	Text  string
}

type agentCtx struct {
	OK      bool
	State   string
	Since   int64 // when it entered that state
	Asked   tEvent
	Said    tEvent
	Pending tEvent // a tool call with no result yet
	Tools   []tEvent
	Strip   [trackCount][stripBins]int
	Counts  [trackCount]int
	Errors  int
	Events  []tEvent // for the timeline
	Read    int64

	// Context window: tokens the last turn sent, the most any turn sent,
	// how often it compacted, and the model.
	Model    string
	CtxUsed  int
	CtxPeak  int
	Compacts int
}

type ctxMsg map[string]agentCtx

// transcriptPath finds a session's transcript.
func transcriptPath(session string) string {
	if session == "" || strings.ContainsAny(session, "/*?[") {
		return ""
	}
	ms, _ := filepath.Glob(filepath.Join(homeDir(), ".claude", "projects", "*", session+".jsonl"))
	if len(ms) == 0 {
		return ""
	}
	return ms[0]
}

func loadCtxCmd(seats []Seat, now int64) tea.Cmd {
	var want []Seat
	for _, s := range seats {
		if toolOf(s) == "claude" && s.Session != "" && now-s.Epoch < 6*3600 {
			want = append(want, s)
		}
	}
	return func() tea.Msg {
		out := ctxMsg{}
		for _, s := range want {
			if c, ok := readCtx(transcriptPath(s.Session), time.Now().Unix()); ok {
				out[s.Addr] = c
			}
		}
		return out
	}
}

type tRecord struct {
	Type        string `json:"type"`
	Timestamp   string `json:"timestamp"`
	IsMeta      bool   `json:"isMeta"`
	IsSidechain bool   `json:"isSidechain"`
	Compact     bool   `json:"isCompactSummary"`
	LastPrompt  string `json:"lastPrompt"`
	Message     struct {
		Role    string          `json:"role"`
		Model   string          `json:"model"`
		Content json.RawMessage `json:"content"`
		Usage   *struct {
			Input       int `json:"input_tokens"`
			CacheRead   int `json:"cache_read_input_tokens"`
			CacheCreate int `json:"cache_creation_input_tokens"`
			Output      int `json:"output_tokens"`
		} `json:"usage"`
	} `json:"message"`
}

type tBlock struct {
	Type    string          `json:"type"`
	Text    string          `json:"text"`
	Name    string          `json:"name"`
	ID      string          `json:"id"`
	Input   json.RawMessage `json:"input"`
	UseID   string          `json:"tool_use_id"`
	IsError bool            `json:"is_error"`
}

var crossFrom = regexp.MustCompile(`<cross-session-message from="([^"]*)"(?: from-name="([^"]*)")?[^>]*>([\s\S]*?)(?:</cross-session-message>|$)`)

// readCtx parses the tail of a transcript.
func readCtx(path string, now int64) (agentCtx, bool) {
	var c agentCtx
	if path == "" {
		return c, false
	}
	f, err := os.Open(path)
	if err != nil {
		return c, false
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return c, false
	}
	start := max(0, fi.Size()-tailBytes)
	if _, err := f.Seek(start, io.SeekStart); err != nil {
		return c, false
	}
	data, err := io.ReadAll(f)
	if err != nil {
		return c, false
	}
	lines := strings.Split(string(data), "\n")
	if start > 0 && len(lines) > 0 {
		lines = lines[1:] // a partial first line
	}
	c.OK, c.Read = true, now
	pending := map[string]tEvent{}
	var last tRecord
	var lastAt int64
	for _, l := range lines {
		if l == "" || l[0] != '{' {
			continue
		}
		var r tRecord
		if json.Unmarshal([]byte(l), &r) != nil {
			continue
		}
		if r.Type == "last-prompt" && strings.TrimSpace(r.LastPrompt) != "" && c.Asked.Text == "" {
			c.Asked.Text = r.LastPrompt
		}
		if (r.Type != "user" && r.Type != "assistant") || r.IsSidechain {
			continue
		}
		at := parseTS(r.Timestamp)
		if at == 0 {
			continue
		}
		if !r.Compact {
			last, lastAt = r, at
		}
		if r.Compact {
			c.Compacts++
		}
		if u := r.Message.Usage; r.Type == "assistant" && u != nil {
			if used := u.Input + u.CacheRead + u.CacheCreate; used > 0 {
				c.CtxUsed = used
				c.CtxPeak = max(c.CtxPeak, used)
			}
			if r.Message.Model != "" && !strings.HasPrefix(r.Message.Model, "<") {
				c.Model = r.Message.Model
			}
		}
		var blocks []tBlock
		var s string
		if json.Unmarshal(r.Message.Content, &s) == nil {
			blocks = []tBlock{{Type: "text", Text: s}}
		} else {
			_ = json.Unmarshal(r.Message.Content, &blocks)
		}
		for _, b := range blocks {
			switch {
			case r.Type == "user" && b.Type == "text":
				t := strings.TrimSpace(b.Text)
				if mm := crossFrom.FindStringSubmatch(t); mm != nil {
					who := mm[2]
					if who == "" {
						who = mm[1]
					}
					ev := tEvent{Epoch: at, Kind: "msg-in", Who: who, Text: strings.TrimSpace(mm[3])}
					c.Events = append(c.Events, ev)
					c.bump(trackTalk, at, now)
					continue
				}
				if r.IsMeta || r.Compact || t == "" || strings.HasPrefix(t, "<") || strings.HasPrefix(t, "Caveat:") {
					continue
				}
				c.Asked = tEvent{Epoch: at, Kind: "asked", Text: t}
				c.Events = append(c.Events, c.Asked)
			case r.Type == "user" && b.Type == "tool_result":
				if b.IsError {
					c.Errors++
				}
				delete(pending, b.UseID)
			case r.Type == "assistant" && b.Type == "text" && strings.TrimSpace(b.Text) != "":
				c.Said = tEvent{Epoch: at, Kind: "said", Text: strings.TrimSpace(b.Text)}
				c.Events = append(c.Events, c.Said)
			case r.Type == "assistant" && b.Type == "tool_use":
				ev := tEvent{Epoch: at, Kind: "tool", Who: b.Name, Text: toolArg(b.Name, b.Input)}
				if b.Name == "SendMessage" {
					var in struct{ To, Message string }
					_ = json.Unmarshal(b.Input, &in)
					ev = tEvent{Epoch: at, Kind: "msg-out", Who: in.To, Text: strings.TrimSpace(in.Message)}
					c.Events = append(c.Events, ev)
					ev = tEvent{Epoch: at, Kind: "tool", Who: "→ " + in.To, Text: ev.Text}
				}
				pending[b.ID] = ev
				c.Tools = append(c.Tools, ev)
				c.bump(track(b.Name), at, now)
			}
		}
	}
	if lastAt == 0 {
		return c, true
	}
	if len(c.Tools) > 3 {
		c.Tools = c.Tools[len(c.Tools)-3:]
	}
	if len(c.Events) > 300 {
		c.Events = c.Events[len(c.Events)-300:]
	}
	if c.Asked.Epoch == 0 && c.Asked.Text != "" {
		c.Asked.Kind = "asked"
	}
	// State, from the last record.
	var p tEvent
	for _, ev := range pending {
		if ev.Epoch >= p.Epoch {
			p = ev
		}
	}
	idle := now - lastAt
	switch {
	case p.Epoch > 0 && p.Epoch >= lastAt-1:
		c.State, c.Since, c.Pending = stateTool, p.Epoch, p
	case last.Type == "assistant" && !hasToolUse(last):
		c.State, c.Since = stateDone, lastAt
	case idle < 5*60:
		c.State, c.Since = stateWork, lastAt
	default:
		c.State, c.Since = stateQuiet, lastAt
	}
	return c, true
}

func hasToolUse(r tRecord) bool {
	var blocks []tBlock
	if json.Unmarshal(r.Message.Content, &blocks) != nil {
		return false
	}
	for _, b := range blocks {
		if b.Type == "tool_use" {
			return true
		}
	}
	return false
}

func (c *agentCtx) bump(track int, at, now int64) {
	c.Counts[track]++
	age := now - at
	if age < 0 || age >= stripBins*stripSecs {
		return
	}
	c.Strip[track][stripBins-1-int(age/stripSecs)]++
}

func track(tool string) int {
	switch tool {
	case "Edit", "Write", "MultiEdit", "NotebookEdit":
		return trackEdit
	case "Bash":
		return trackBash
	case "SendMessage", "Agent", "Task":
		return trackTalk
	}
	return trackRead
}

// toolArg is a tool call's gist: the file it touched or the command it ran.
func toolArg(name string, raw json.RawMessage) string {
	var in map[string]any
	if json.Unmarshal(raw, &in) != nil {
		return ""
	}
	for _, k := range []string{"command", "file_path", "path", "pattern", "description", "prompt", "url", "query"} {
		if v, ok := in[k].(string); ok && v != "" {
			v = strings.Join(strings.Fields(v), " ")
			if strings.HasPrefix(v, homeDir()) {
				v = "~" + strings.TrimPrefix(v, homeDir())
			}
			return v
		}
	}
	return ""
}

func parseTS(s string) int64 {
	if s == "" {
		return 0
	}
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return 0
	}
	return t.Unix()
}

// stateLine is the agent's state in a few words, and how it should look.
func (c agentCtx) stateLine(now int64) (string, string) {
	d := ago(now, c.Since)
	switch c.State {
	case stateTool:
		if now-c.Since > pendingSlow {
			return "waiting on " + c.Pending.Who + " · " + d + " (a permission prompt?)", "warn"
		}
		return "working · running " + c.Pending.Who + " · " + d, "good"
	case stateWork:
		return "working · " + d + " ago", "good"
	case stateDone:
		return "done · at its prompt " + d, "dim"
	case stateQuiet:
		return "quiet " + d, "dim"
	}
	return "", "dim"
}

// glyph is the state as one character for the table.
func (c agentCtx) glyph(now int64) (string, string) {
	switch c.State {
	case stateTool:
		if now-c.Since > pendingSlow {
			return "◆", "warn"
		}
		return "●", "good"
	case stateWork:
		return "●", "good"
	case stateDone:
		return "✓", "dim"
	}
	return " ", "dim"
}

// window is the context window's size and whether that is a guess. The
// transcript doesn't record it: a session that ever sent over 200k tokens
// has the 1M window; otherwise assume 200k, unless AGENT_BUS_CONTEXT_WINDOW
// says otherwise.
func (c agentCtx) window() (int, bool) {
	if v, err := strconv.Atoi(strings.TrimSpace(getenv("AGENT_BUS_CONTEXT_WINDOW"))); err == nil && v > 0 {
		return v, false
	}
	if strings.Contains(c.Model, "[1m]") || c.CtxPeak > 200_000 {
		return 1_000_000, false
	}
	return 200_000, true
}

// ctxPct is how full its context is, 0-100, or -1 when unknown.
func (c agentCtx) ctxPct() int {
	if c.CtxUsed == 0 {
		return -1
	}
	w, _ := c.window()
	return min(100, c.CtxUsed*100/w)
}

func ctxTone(pct int) string {
	switch {
	case pct >= 85:
		return "bad"
	case pct >= 65:
		return "warn"
	}
	return "dim"
}

// meter draws pct as n cells: ▰▰▰▱▱.
func meter(pct, n int) string {
	full := (pct*n + 50) / 100
	return strings.Repeat("▰", full) + strings.Repeat("▱", n-full)
}

func kTokens(n int) string {
	if n >= 1_000_000 {
		return strconv.FormatFloat(float64(n)/1e6, 'f', 1, 64) + "M"
	}
	return strconv.Itoa((n+500)/1000) + "k"
}
