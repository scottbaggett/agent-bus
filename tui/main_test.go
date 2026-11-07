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
		},
	}
	n := m.needs()
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

func TestSearchFilters(t *testing.T) {
	for _, c := range []struct {
		hay, term string
		want      bool
	}{
		{"wiring the invoices api", "inv", true},
		{"feature/salt-9473-fix", "9473", true},
		{":3003 :3107", "3003", true},
		{"salt-mobile-native", "salt-mobile", true},
		{"salt-monorepo", "repo", false}, // not a word start
		{"bold mantis", "ae", false},
	} {
		if got := wordPrefix(c.hay, c.term); got != c.want {
			t.Errorf("wordPrefix(%q, %q) = %v", c.hay, c.term, got)
		}
	}
	if !initials("bold mantis", "bm") || initials("bold mantis", "mb") {
		t.Error("initials")
	}
	m := newModel()
	m.snap = &Snapshot{Seats: []Seat{
		{Addr: "codex/api.1", Tool: "codex", Repo: "salt", Focus: "Wiring the invoices API", Branch: "feature/salt-1234"},
		{Addr: "claude/web.2", Tool: "claude", Repo: "salt", Focus: "Landing page copy"},
		{Addr: "claude/mobile-native.3", Tool: "claude", Repo: "salt"},
	}}
	for q, want := range map[string][]string{
		"invoice 1234":               {"codex/api.1"},
		friendlyName("claude/web.2"): {"claude/web.2"},
		"mobile":                     {"claude/mobile-native.3"},
		"claude":                     nil,             // the tool is shared, not a filter
		"salt":                       {"codex/api.1"}, // repo ignored; branch matches
	} {
		m.query = q
		tiles, _ := m.tiles()
		var got []string
		for _, t := range tiles {
			got = append(got, t.seat.Addr)
		}
		if strings.Join(got, ",") != strings.Join(want, ",") {
			t.Errorf("search %q: got %v, want %v", q, got, want)
		}
	}
}
