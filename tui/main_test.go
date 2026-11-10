package main

import (
	"os/exec"
	"strconv"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestCleanStripsControlCharacters(t *testing.T) {
	got := clean("ok\x1b[2J\x1b]52;c;evil\x07 done\nnext")
	if strings.ContainsAny(got, "\x1b\x07\n") {
		t.Fatalf("control characters survived: %q", got)
	}
}

func TestAgo(t *testing.T) {
	for _, c := range []struct {
		d    int64
		want string
	}{{5, "5s"}, {120, "2m"}, {7200, "2h"}, {172800, "2d"}} {
		if got := ago(1000000, 1000000-c.d); got != c.want {
			t.Errorf("ago(%d) = %q, want %q", c.d, got, c.want)
		}
	}
}

func TestRenderShowReadsTheHeader(t *testing.T) {
	out := `{"id":"x-1","from":"codex/a.1","to":"@lead","state":"question","epoch":1,"repo":"r","branch":"b","touched":["a.go"]}
---
Drop the \x1b[31mtable?`
	got := ansi.Strip(renderShow(out, 80))
	for _, want := range []string{"codex/a.1", "@lead", "question", "r · b", "a.go", "Drop the"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in:\n%s", want, got)
		}
	}
}

func TestNeedsGroupByAgentAndKeepExitedOnes(t *testing.T) {
	m := newModel()
	m.snap = &Snapshot{
		Now:   100,
		Seats: []Seat{{Addr: "codex/api.1", Tool: "codex", Epoch: 99}},
		Open: []Item{
			{ID: "a", From: "codex/api.1", To: "@lead", State: "question", Subject: "drop it?"},
			{ID: "b", From: "claude/web.2", To: "lead/x.1", State: "handoff", Subject: "done"},
			{ID: "c", From: "codex/api.1", To: "claude/web.2", Subject: "not for you"},
			{ID: "d", From: "codex/api.1", To: "@lead", Subject: "old", Stale: true},
			{ID: "e", From: "claude/gone.3", To: "@lead", Subject: "days old", Stale: true},
		},
		Attention: []Att{{Kind: "needs-you", ID: "e", From: "claude/gone.3", Text: "claude/gone.3 asks you: days old"}},
	}
	n := m.needs()
	if len(n["claude/gone.3"]) != 0 {
		t.Fatalf("a stale ask from an exited agent still counts: %+v", n["claude/gone.3"])
	}
	if len(n["codex/api.1"]) != 1 || n["codex/api.1"][0].ID != "a" {
		t.Fatalf("codex needs: %+v", n["codex/api.1"])
	}
	tiles, _ := m.tiles()
	var gone []string
	for _, t := range tiles {
		if t.gone {
			gone = append(gone, t.seat.Addr)
		}
	}
	if len(tiles) != 2 || len(gone) != 1 || gone[0] != "claude/web.2" {
		t.Fatalf("tiles: %+v", tiles)
	}
}

func TestMidFitKeepsTheInstance(t *testing.T) {
	if got := midFit("salt-monorepo.0b81", 14); got != "salt-mon….0b81" {
		t.Fatalf("got %q", got)
	}
	if got := midFit("main.8e66", 14); got != "main.8e66" {
		t.Fatalf("got %q", got)
	}
}

func TestNamesAndRobotsVary(t *testing.T) {
	names, robots := map[string]bool{}, map[string]bool{}
	for i := 0; i < 40; i++ {
		a := "claude/salt-monorepo." + strconv.Itoa(1000+i)
		names[friendlyName(a)] = true
		robots[avatarArt(a, "claude", false)] = true
	}
	if len(names) < 30 || len(robots) < 30 {
		t.Fatalf("too little variety: %d names, %d robots of 40", len(names), len(robots))
	}
	if friendlyName("codex/api.1") != friendlyName("codex/api.1") {
		t.Fatal("names must be stable")
	}
}

func TestWorkingOn(t *testing.T) {
	for _, c := range []struct {
		s    Seat
		want string
	}{
		{Seat{Branch: "feature/salt-9473-fix-thing"}, "SALT-9473"},
		{Seat{Branch: "main", Repo: "salt-monorepo"}, "salt-monorepo"},
		{Seat{Branch: "feat/tui"}, "tui"},
	} {
		if got := workingOn(c.s); got != c.want {
			t.Errorf("workingOn(%+v) = %q, want %q", c.s, got, c.want)
		}
	}
}

func TestNamesMatchTheCLI(t *testing.T) {
	for _, a := range []string{"claude/salt-monorepo.44b1", "codex/api.1", "opencode/docs.2e7d"} {
		out, err := exec.Command("../bin/agent-bus", "avatar", a).Output()
		if err != nil {
			t.Skip("bin/agent-bus not runnable here")
		}
		if !strings.Contains(string(out), friendlyName(a)+" · "+a) {
			t.Errorf("CLI and TUI name %s differently: CLI said %q, TUI %q", a, strings.TrimSpace(string(out)), friendlyName(a))
		}
	}
}

func TestFuzzySearch(t *testing.T) {
	for _, c := range []struct {
		hay, term string
		want      bool
	}{
		{"bold mantis", "bm", true},
		{"bold mantis", "mant", true},
		{"wiring the invoices api", "inv", true},
		{"bold mantis", "ae", false},
		{"salt-9473", "9473", true},
	} {
		if got := fuzzy(c.hay, c.term); got != c.want {
			t.Errorf("fuzzy(%q, %q) = %v", c.hay, c.term, got)
		}
	}
	m := newModel()
	m.snap = &Snapshot{Seats: []Seat{
		{Addr: "codex/api.1", Tool: "codex", Focus: "Wiring the invoices API", Branch: "feature/salt-1234"},
		{Addr: "claude/web.2", Tool: "claude", Focus: "Landing page copy"},
	}}
	m.query = "invoice 1234"
	if tiles, _ := m.tiles(); len(tiles) != 1 || tiles[0].seat.Addr != "codex/api.1" {
		t.Fatalf("search: %+v", tiles)
	}
	m.query = friendlyName("claude/web.2")
	if tiles, _ := m.tiles(); len(tiles) != 1 || tiles[0].seat.Addr != "claude/web.2" {
		t.Fatalf("search by name: %+v", tiles)
	}
}
