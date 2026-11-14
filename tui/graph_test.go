package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func graphModel() model {
	m := newModel()
	m.snap = &Snapshot{
		Now: 1000,
		Seats: []Seat{
			{Addr: "claude/main.pm", Lane: "tools", Repo: "r", Branch: "develop", Epoch: 999},
			{Addr: "claude/a.1", Lane: "tools", Repo: "r", Branch: "feat/salt-1-a", Epoch: 999},
			{Addr: "codex/b.2", Repo: "r", Branch: "fix/salt-1-b", Epoch: 999}, // same ticket as a.1
			{Addr: "claude/c.3", Repo: "r", Branch: "develop", Epoch: 999},     // messaged the reviewer by role
			{Addr: "claude/rev.4", Repo: "r", Branch: "develop", Epoch: 999},
			{Addr: "claude/alone.5", Repo: "r", Branch: "develop", Epoch: 999},
			{Addr: "claude/broadcast.6", Repo: "r", Branch: "develop", Epoch: 999}, // only ever posted to @here
		},
		Roles: map[string]map[string]string{"x": {"reviewer": "claude/rev.4"}},
		Lanes: []Lane{{Lane: "tools", PM: "claude/main.pm"}},
		Recent: []Event{
			{Kind: "msg", ID: "1", From: "claude/c.3", To: "@reviewer"},
			{Kind: "msg", ID: "2", From: "claude/broadcast.6", To: "@here"},
			{Kind: "delivery", ID: "1", To: "claude/rev.4"},
		},
	}
	return m
}

func TestGraphClustersAgentsThatWorkTogether(t *testing.T) {
	m := graphModel()
	tiles, _ := m.tiles()
	clusters, solo := m.graph(tiles)
	names := func(ix []int) string {
		var out []string
		for _, i := range ix {
			out = append(out, tiles[i].seat.Addr)
		}
		return strings.Join(out, " ")
	}
	got := map[string]string{}
	for _, c := range clusters {
		got[c.name] = names(c.nodes)
	}
	if len(clusters) != 2 {
		t.Fatalf("want 2 clusters, got %v", got)
	}
	tools := got["tools"]
	if !strings.HasPrefix(tools, "claude/main.pm ") || !strings.Contains(tools, "claude/a.1") || !strings.Contains(tools, "codex/b.2") {
		t.Errorf("tools cluster should be the PM, its lane and the ticket-mate, PM first: %q", tools)
	}
	var other string
	for k, v := range got {
		if k != "tools" {
			other = v
		}
	}
	if !strings.Contains(other, "claude/c.3") || !strings.Contains(other, "claude/rev.4") {
		t.Errorf("a message to @reviewer should join c.3 and rev.4: %v", got)
	}
	if s := names(solo); !strings.Contains(s, "alone.5") || !strings.Contains(s, "broadcast.6") {
		t.Errorf("agents joined to no one (broadcasts don't count) should be on their own: %q", s)
	}
}

func TestGraphRingNeverOverlaps(t *testing.T) {
	for n := 2; n <= 9; n++ {
		xy, w, h, ok := spread(n, 400)
		if !ok {
			t.Fatalf("n=%d did not fit", n)
		}
		for i := range xy {
			if xy[i][0] < 0 || xy[i][1] < 0 || xy[i][0]+chipW > w || xy[i][1]+chipH > h {
				t.Errorf("n=%d chip %d outside the canvas", n, i)
			}
			for j := i + 1; j < n; j++ {
				if abs(xy[i][0]-xy[j][0]) < chipW && abs(xy[i][1]-xy[j][1]) < chipH {
					t.Errorf("n=%d chips %d and %d overlap", n, i, j)
				}
			}
		}
	}
	if _, _, _, ok := spread(9, 60); ok {
		t.Error("a ring wider than the pane should fall back to rows")
	}
}

func TestGraphViewDrawsAndSelects(t *testing.T) {
	m := graphModel()
	m.w, m.h, m.view = 160, 50, viewGraph
	for _, view := range []int{viewGraph, viewBots} {
		m.view = view
		lines := strings.Split(m.View(), "\n")
		if len(lines) != m.h {
			t.Fatalf("view %d renders %d rows, want %d", view, len(lines), m.h)
		}
		for row, line := range lines {
			if width := ansi.StringWidth(line); width > m.w {
				t.Errorf("view %d row %d is %d columns, limit %d", view, row, width, m.w)
			}
		}
	}
	m.view = viewGraph
	// Every agent can be reached with the arrows.
	tiles, _ := m.tiles()
	reached, queue := map[int]bool{0: true}, []int{0}
	for len(queue) > 0 {
		from := queue[0]
		queue = queue[1:]
		for _, d := range [][2]int{{1, 0}, {0, 1}, {-1, 0}, {0, -1}} {
			m.cursor[paneAgents] = from
			m.moveGrid(d[0], d[1], m.gridW())
			if to := m.cursor[paneAgents]; !reached[to] {
				reached[to] = true
				queue = append(queue, to)
			}
		}
	}
	if len(reached) != len(tiles) {
		_, pos := m.gridLayout(m.gridW())
		t.Errorf("arrows reached %d of %d agents: %v %+v", len(reached), len(tiles), reached, pos)
	}
}

func TestSeatNamedMatchesShortWorktreeNames(t *testing.T) {
	m := newModel()
	m.snap = &Snapshot{Seats: []Seat{{Addr: "claude/feature-salt-9948-thread-tool-state.7310"}, {Addr: "claude/salt-99.a"}, {Addr: "claude/salt-99.b"}}}
	if got := m.seatNamed("salt-9948"); got != "claude/feature-salt-9948-thread-tool-state.7310" {
		t.Errorf("got %q", got)
	}
	if got := m.seatNamed("salt-99"); got != "" {
		t.Errorf("two seats share the name, so don't guess: %q", got)
	}
}
