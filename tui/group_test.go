package main

import "testing"

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
