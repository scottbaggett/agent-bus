package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func TestMentionedTicketsReadsBareNumbersInAList(t *testing.T) {
	got := strings.Join(mentionedTickets("PM: seats on SALT-9936, 9935, 9938; no engineering"), " ")
	if got != "SALT-9936 SALT-9935 SALT-9938" {
		t.Fatalf("got %q", got)
	}
}

func teamsModel() model {
	m := newModel()
	m.snap = &Snapshot{
		Now: 100000,
		Seats: []Seat{
			{Addr: "claude/main.pm", Repo: "mono", Lane: "tools", Focus: "PM for tools: seats on SALT-100, 200", Epoch: 99990},
			{Addr: "claude/salt-1.a", Repo: "mono", Branch: "salt-100-x", Epoch: 99980},
			{Addr: "claude/salt-2.b", Repo: "mono", Branch: "feat/salt-200-y", Epoch: 99000},
			{Addr: "claude/salt-7.c", Repo: "mono", Branch: "salt-7-z", Epoch: 99900},           // one agent, own group
			{Addr: "claude/main.d", Repo: "dotfiles", Branch: "main", Epoch: 99950},             // no ticket: by repo
			{Addr: "claude/main.old", Repo: "dotfiles", Branch: "main", Epoch: 100000 - 3*3600}, // idle, folds
			{Addr: "claude/main.gone", Repo: "x", Branch: "main", Epoch: 100000 - 5*3600},       // idle, whole group folds
			{Addr: "codex/q.1", Repo: "mono", Branch: "main", Epoch: 99999},                     // waits on you
		},
		Open: []Item{{ID: "q1", From: "codex/q.1", To: "@lead", State: "question", Subject: "ship it?", Epoch: 99999}},
	}
	return m
}

func TestTeamsGroupByPMThenTicketThenRepo(t *testing.T) {
	m := teamsModel()
	tiles, _ := m.tiles()
	teams, folded := m.teams(tiles)
	got := map[string]string{}
	var order []string
	for _, tm := range teams {
		var rows []string
		for _, i := range tm.rows {
			rows = append(rows, tiles[i].seat.Addr)
		}
		got[tm.title] = strings.Join(rows, " ")
		order = append(order, tm.title)
	}
	if got["tools"] != "claude/main.pm claude/salt-1.a claude/salt-2.b" {
		t.Errorf("PM team should lead with its PM and hold its tickets' agents: %q", got["tools"])
	}
	if got["salt-7"] != "claude/salt-7.c" {
		t.Errorf("a one-agent ticket keeps its own group: %v", got)
	}
	if got["dotfiles"] != "claude/main.d" {
		t.Errorf("no-ticket agents group by repo, idle ones fold: %v", got)
	}
	if order[0] != "mono" {
		t.Errorf("the group with something waiting on you comes first: %v", order)
	}
	if len(folded) != 1 || tiles[folded[0]].seat.Addr != "claude/main.gone" {
		t.Errorf("a group with no live agent folds whole: %v", folded)
	}
	m.showIdle = true
	if _, folded := m.teams(tiles); len(folded) != 0 {
		t.Error("z shows idle agents")
	}
}

func TestTeamsNavigationOpensOwnedQuestionAndCyclesViews(t *testing.T) {
	m := teamsModel()
	m.w, m.h = 160, 50
	m.clamp()
	mm, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("n")})
	got := mm.(model)
	if got.mode != modePanel || got.panel.seat.Addr != "codex/q.1" {
		t.Errorf("n should open the agent waiting on you, got %q mode %d", got.panel.seat.Addr, got.mode)
	}
	for _, want := range []int{viewGraph, viewBots, viewTeams} {
		mm, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("g")})
		m = mm.(model)
		if m.view != want {
			t.Fatalf("view cycle reached %d, want %d", m.view, want)
		}
		if _, ok := m.selectedTile(); !ok {
			t.Fatal("cycling views lost the selected agent")
		}
	}
}

func TestNarrowScreenStacksThePanelAndRowsNeverWrap(t *testing.T) {
	for _, w := range []int{70, 90, 120, 139} {
		m := teamsModel()
		m.w, m.h = w, 50
		m.clamp()
		mm, _ := m.openPanel()
		v := mm.(model)
		if !v.stacked() || v.panelW() != 0 {
			t.Errorf("w=%d: the panel should sit under the agents", w)
		}
		lines := strings.Split(v.View(), "\n")
		if len(lines) != 50 {
			t.Errorf("w=%d: view is %d lines, want 50", w, len(lines))
		}
		for i, l := range lines {
			if lw := ansi.StringWidth(l); lw > w {
				t.Errorf("w=%d: line %d is %d wide: %q", w, i, lw, ansi.Strip(l))
				break
			}
		}
	}
	m := teamsModel()
	m.w, m.h = 170, 50
	m.clamp()
	mm, _ := m.openPanel()
	if v := mm.(model); v.stacked() || v.panelW() == 0 {
		t.Error("a wide screen keeps the panel beside the agents")
	}
}

func TestMRChecksAndRef(t *testing.T) {
	p := prInfo{Kind: "MR", Number: 3886, Pipeline: "running"}
	if p.ref() != "!3886" {
		t.Errorf("an MR is written !3886, got %s", p.ref())
	}
	if s, tone := p.checks(); tone != "warn" {
		t.Errorf("got %q %s", s, tone)
	}
	if s, tone := (prInfo{Kind: "MR", Pipeline: "failed"}).checks(); tone != "bad" {
		t.Errorf("got %q %s", s, tone)
	}
	if (prInfo{Kind: "PR", Number: 12}).ref() != "#12" {
		t.Error("a PR is written #12")
	}
}
