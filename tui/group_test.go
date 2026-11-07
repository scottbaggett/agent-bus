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
