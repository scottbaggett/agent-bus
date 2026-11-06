package main

import (
	"os/exec"
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

func TestWorkRowsHideStaleUntilAsked(t *testing.T) {
	m := newModel()
	m.snap = &Snapshot{Open: []Item{{ID: "a", Subject: "live"}, {ID: "b", Subject: "old", Stale: true}}}
	m.tab = tabOpen
	if n := len(m.workRows()); n != 1 {
		t.Fatalf("got %d rows, want 1", n)
	}
	m.showStale = true
	if n := len(m.workRows()); n != 2 {
		t.Fatalf("got %d rows with stale shown, want 2", n)
	}
	m.filter = "old"
	if rows := m.workRows(); len(rows) != 1 || rows[0].id != "b" {
		t.Fatalf("filter: got %+v", rows)
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

func TestAvatarMatchesTheCLI(t *testing.T) {
	// agent-bus avatar codex/api.628b, from bin/agent-bus.
	got := strings.Join(avatarRows("codex/api.628b", "codex"), "\n")
	if want := cliAvatar(t, "codex/api.628b"); want != "" && got != want {
		t.Fatalf("TUI and CLI draw different bots:\n%s\n---\n%s", got, want)
	}
}

func cliAvatar(t *testing.T, addr string) string {
	out, err := exec.Command("../bin/agent-bus", "avatar", addr).Output()
	if err != nil {
		t.Skip("bin/agent-bus not runnable here")
	}
	var rows []string
	for _, l := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		l = strings.TrimPrefix(l, "  ")
		if l != addr {
			rows = append(rows, l)
		}
	}
	return strings.Join(rows, "\n")
}
