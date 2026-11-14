package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

const transcriptFixture = `{"type":"last-prompt","lastPrompt":"old prompt"}
{"type":"user","timestamp":"2026-11-11T20:00:00Z","message":{"role":"user","content":"Take SALT-100 and verify it"}}
{"type":"assistant","timestamp":"2026-11-11T20:00:10Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x/a.go"}}]}}
{"type":"user","timestamp":"2026-11-11T20:00:11Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
{"type":"user","timestamp":"2026-11-11T20:01:00Z","isMeta":true,"message":{"role":"user","content":"Another Claude session sent a message:\n<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-name=\"salt-200\" from-mode=\"prompting\">Done with the fix</cross-session-message>"}}
{"type":"assistant","timestamp":"2026-11-11T20:01:05Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"SendMessage","input":{"to":"salt-200","message":"Accepted, ship it"}}]}}
{"type":"user","timestamp":"2026-11-11T20:01:06Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"sent"}]}}
{"type":"assistant","timestamp":"2026-11-11T20:01:20Z","message":{"role":"assistant","content":[{"type":"text","text":"SALT-100 is verified."}]}}
`

func writeTranscript(t *testing.T, body string) string {
	p := filepath.Join(t.TempDir(), "s.jsonl")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestTranscriptReadsStateAskedSaidAndSessionMessages(t *testing.T) {
	now := parseTS("2026-11-11T20:02:00Z")
	c, ok := readCtx(writeTranscript(t, transcriptFixture), now)
	if !ok || c.State != stateDone {
		t.Fatalf("a final assistant text means done at its prompt: %+v", c.State)
	}
	if c.Asked.Text != "Take SALT-100 and verify it" || c.Said.Text != "SALT-100 is verified." {
		t.Errorf("asked %q said %q", c.Asked.Text, c.Said.Text)
	}
	var in, out tEvent
	for _, e := range c.Events {
		switch e.Kind {
		case "msg-in":
			in = e
		case "msg-out":
			out = e
		}
	}
	if in.Who != "salt-200" || in.Text != "Done with the fix" || out.Who != "salt-200" || out.Text != "Accepted, ship it" {
		t.Errorf("session messages: in %+v out %+v", in, out)
	}
	if c.Counts[trackRead] != 1 || c.Counts[trackTalk] != 2 {
		t.Errorf("counts %v", c.Counts)
	}
}

func TestTranscriptPendingToolBecomesWaiting(t *testing.T) {
	body := transcriptFixture + `{"type":"assistant","timestamp":"2026-11-11T20:02:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"psql -c 'select 1'"}}]}}` + "\n"
	c, _ := readCtx(writeTranscript(t, body), parseTS("2026-11-11T20:02:10Z"))
	if line, tone := c.stateLine(parseTS("2026-11-11T20:02:10Z")); c.State != stateTool || c.Pending.Who != "Bash" || tone != "good" {
		t.Errorf("a fresh tool call is working: %q %s", line, tone)
	}
	if line, tone := c.stateLine(parseTS("2026-11-11T20:05:00Z")); c.State != stateTool || c.Pending.Who != "Bash" || tone != "warn" {
		t.Errorf("a tool pending for minutes may be waiting on you: %q %s", line, tone)
	}
}

func TestServicesBelongToTheirOwnAgentNotTheRepoRoot(t *testing.T) {
	m := newModel()
	m.snap = &Snapshot{Seats: []Seat{
		{Addr: "claude/main.pm", Cwd: "/r/mono", Pid: 10},
		{Addr: "claude/salt-1.a", Cwd: "/r/mono/.claude/worktrees/salt-1", Pid: 20},
	}}
	m.services = []service{
		{Port: 3000, Cwd: "/r/mono/.claude/worktrees/salt-1/web", Up: []int{99}},
		{Port: 3001, Cwd: "/r/mono/.claude/worktrees/salt-2", Up: []int{98}}, // a worktree nobody here owns
		{Port: 3002, Cwd: "/tmp", Up: []int{55, 10}},                         // started by the PM's process
	}
	if got := ports(m.servicesFor(m.snap.Seats[0])); got != ":3002" {
		t.Errorf("PM should own only what its process started, got %q", got)
	}
	if got := ports(m.servicesFor(m.snap.Seats[1])); got != ":3000" {
		t.Errorf("the worktree agent owns its folder's server, got %q", got)
	}
}

func TestPanelLeadsWithStateAndPMTeamHoldsWhoItMessages(t *testing.T) {
	m := teamsModel()
	m.snap.Seats = append(m.snap.Seats, Seat{Addr: "claude/salt-300.e", Repo: "mono", Branch: "develop", Epoch: 99990})
	now := m.snap.Now
	m.ctx = map[string]agentCtx{
		"claude/main.pm":  {OK: true, State: stateDone, Since: now - 5, Events: []tEvent{{Kind: "msg-out", Who: "salt-300", Epoch: now - 60}}},
		"claude/salt-1.a": {OK: true, State: stateTool, Since: now - 300, Pending: tEvent{Who: "Bash", Text: "rm -rf x"}},
	}
	tiles, _ := m.tiles()
	teams, _ := m.teams(tiles)
	for _, tm := range teams {
		if tm.title == "tools" {
			var rows []string
			for _, i := range tm.rows {
				rows = append(rows, tiles[i].seat.Addr)
			}
			if !strings.Contains(strings.Join(rows, " "), "claude/salt-300.e") {
				t.Errorf("an agent the PM messages joins its team: %v", rows)
			}
		}
	}
	for i, tl := range tiles {
		if tl.seat.Addr == "claude/salt-1.a" {
			m.cursor[paneAgents] = i
		}
	}
	m.w, m.h = 170, 50
	mm, _ := m.openPanel()
	out := ansi.Strip(mm.(model).View())
	if !strings.Contains(out, m.ctx["claude/salt-1.a"].Pending.Text) {
		t.Error("selected agent's pending command was not rendered")
	}
}

func TestTranscriptReadsContextUse(t *testing.T) {
	body := `{"type":"assistant","timestamp":"2026-11-11T20:00:00Z","message":{"role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"a"}],"usage":{"input_tokens":2,"cache_read_input_tokens":250000,"cache_creation_input_tokens":8,"output_tokens":5}}}
{"type":"user","timestamp":"2026-11-11T20:01:00Z","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued"}}
{"type":"assistant","timestamp":"2026-11-11T20:02:00Z","message":{"role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"b"}],"usage":{"input_tokens":10,"cache_read_input_tokens":89990,"cache_creation_input_tokens":0,"output_tokens":5}}}
`
	c, _ := readCtx(writeTranscript(t, body), parseTS("2026-11-11T20:03:00Z"))
	if c.CtxUsed != 90000 || c.Compacts != 1 || c.Model != "claude-opus-5-5" {
		t.Fatalf("used %d compacts %d model %q", c.CtxUsed, c.Compacts, c.Model)
	}
	if w, guess := c.window(); w != 1_000_000 || guess || c.ctxPct() != 9 {
		t.Errorf("a session that went past 200k has the 1M window: %d %v %d%%", w, guess, c.ctxPct())
	}
	if c.State != stateDone || c.State == stateQuiet {
		t.Errorf("a compaction is not activity: %s", c.State)
	}
}

func TestSwitchingChatDropsPreviousBusHistoryBeforeTranscriptRefresh(t *testing.T) {
	m := teamsModel()
	m.w, m.h = 160, 50
	first, second := m.snap.Seats[0], m.snap.Seats[1]
	m.openChat(first, "")
	updated, _ := m.Update(chatLoaded{addr: first.Addr, msgs: []chatMsg{{ID: "first-agent-packet", Epoch: 1, Kind: "msg"}}})
	m = updated.(model)
	m.openChat(second, "")
	updated, _ = m.Update(ctxMsg{second.Addr: {Events: []tEvent{{Kind: "said", Epoch: 2, Text: "second-agent-result"}}}})
	m = updated.(model)
	if len(m.chatBus) != 0 || len(m.chatMsgs) != 1 || m.chatMsgs[0].Body != "second-agent-result" {
		t.Fatalf("switching agents retained unrelated history: bus=%+v timeline=%+v", m.chatBus, m.chatMsgs)
	}
	updated, _ = m.Update(chatLoaded{addr: first.Addr, msgs: []chatMsg{{ID: "late-first-agent-packet"}}})
	m = updated.(model)
	if m.chatSeat.Addr != second.Addr || len(m.chatMsgs) != 1 || m.chatMsgs[0].Body != "second-agent-result" {
		t.Fatal("a late history load changed the selected agent's chat")
	}
}
