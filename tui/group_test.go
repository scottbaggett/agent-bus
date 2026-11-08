package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestGroupBy(t *testing.T) {
	m := newModel()
	m.snap = &Snapshot{Seats: []Seat{
		{Addr: "codex/api.1", Tool: "codex", Repo: "salt", Lane: "billing"},
		{Addr: "claude/web.2", Tool: "claude", Repo: "salt", Lane: "billing"},
		{Addr: "claude/docs.3", Tool: "claude", Repo: "docs"},
	}}
	for g, want := range map[groupBy]int{byLane: 2, byTool: 2, byRepo: 2, byMac: 1, byNone: 1} {
		m.groupBy = g
		if _, groups := m.tiles(); len(groups) != want {
			t.Errorf("group by %s: %d groups, want %d", g, len(groups), want)
		}
	}
	m.groupBy = byTool
	if _, groups := m.tiles(); groups[0].name != "Claude" && groups[1].name != "Claude" {
		t.Errorf("tool groups: %+v", groups)
	}
}

func TestNotifiesOnlyNewAsks(t *testing.T) {
	m := newModel()
	m.snap = &Snapshot{Seats: []Seat{{Addr: "codex/api.1"}}, Open: []Item{{ID: "a", From: "codex/api.1", To: "@lead", State: "question"}}}
	if n := m.newNeeds(true); len(n) != 0 {
		t.Fatalf("first load announced the backlog: %+v", n)
	}
	m.snap.Open = append(m.snap.Open, Item{ID: "b", From: "codex/api.1", To: "@lead", State: "question"})
	if n := m.newNeeds(false); len(n) != 1 || n[0].ID != "b" {
		t.Fatalf("new asks: %+v", n)
	}
	if n := m.newNeeds(false); len(n) != 0 {
		t.Fatalf("announced twice: %+v", n)
	}
}

func TestOwnPortsSkipShared(t *testing.T) {
	m := newModel()
	m.snap = &Snapshot{Seats: []Seat{{Addr: "a/x.1", Cwd: "/r/x"}, {Addr: "a/x.2", Cwd: "/r/x"}, {Addr: "a/y.1", Cwd: "/r/y"}}}
	m.services = []service{{Port: 3000, Cwd: "/r/x"}, {Port: 4000, Cwd: "/r/y/web"}}
	if p := m.ownPorts(m.snap.Seats[0]); len(p) != 0 {
		t.Errorf("shared port shown: %+v", p)
	}
	if p := m.ownPorts(m.snap.Seats[2]); len(p) != 1 || p[0].Port != 4000 {
		t.Errorf("own port: %+v", p)
	}
}

func TestWaitingInItsWindowNeedsYou(t *testing.T) {
	m := newModel()
	m.snap = &Snapshot{Seats: []Seat{{Addr: "claude/web.2", Activity: "waiting", ActivityAt: 5}, {Addr: "claude/api.1", Activity: "working"}}}
	n := m.needs()
	if len(n["claude/web.2"]) != 1 || !isLive(n["claude/web.2"][0]) || len(n["claude/api.1"]) != 0 {
		t.Fatalf("needs: %+v", n)
	}
}

func TestScreenHeightStable(t *testing.T) {
	m := newModel()
	m.w, m.h = 160, 40
	m.snap = &Snapshot{Now: 100, Seats: []Seat{{Addr: "claude/web.2", Tool: "claude", Epoch: 99}}}
	m.logAddr = "claude/web.2"
	long := strings.Repeat("a long reply that wraps across several lines of the panel ", 20)
	for i := 0; i < 30; i++ {
		m.logMsgs = append(m.logMsgs, chatMsg{Kind: "said", Body: long, Epoch: int64(i)}, chatMsg{Kind: "asked", Body: long, Epoch: int64(i)})
	}
	if got := len(strings.Split(m.View(), "\n")); got != m.h {
		t.Errorf("screen is %d lines, want %d", got, m.h)
	}
	m.logScroll = 10
	if got := len(strings.Split(m.View(), "\n")); got != m.h {
		t.Errorf("scrolled: screen is %d lines, want %d", got, m.h)
	}
}

func TestWheelOverPanelScrollsItsLog(t *testing.T) {
	m := newModel()
	m.w, m.h = 160, 40
	m.snap = &Snapshot{Now: 100, Seats: []Seat{{Addr: "claude/a.1", Tool: "claude", Epoch: 99}, {Addr: "claude/b.2", Tool: "claude", Epoch: 98}}}
	m.logAddr = "claude/a.1"
	for i := 0; i < 50; i++ {
		m.logMsgs = append(m.logMsgs, chatMsg{Kind: "said", Body: "reply", Epoch: int64(i)})
	}
	before := m.cursor[paneAgents]
	mm, _ := m.mouse(tea.MouseMsg{X: m.w - 5, Y: 20, Button: tea.MouseButtonWheelUp, Action: tea.MouseActionPress})
	m = mm.(model)
	if m.cursor[paneAgents] != before || m.logScroll == 0 {
		t.Fatalf("wheel over the panel: cursor %d→%d, scroll %d", before, m.cursor[paneAgents], m.logScroll)
	}
}
