package main

import (
	"os"
	"os/exec"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// The first run opens a short welcome: which agents this Mac has, whether the
// bus is wired into them, and the few keys that matter. After an update,
// "what's new" opens once with that version's highlights. Either comes back
// with w.

// whatsNew is each version's highlights, newest first.
var whatsNew = []struct {
	version string
	notes   []string
}{
	{"0.6.0", []string{
		"Live state: a dot on each agent says working, waiting on you, or idle. An agent stopped on a permission prompt in its own window counts as needing you.",
		"The header numbers the agents that need you; press 1-9 to go to one.",
		"Enter in an agent's panel, or a double-click on its tile, brings its app to the front.",
		"Agents that offboard leave the grid; ^ shows them. O asks an agent to offboard.",
		"Agents can say where their work stands: agent-bus focus --stage review.",
		"g groups by repo, stage, lane, tool or Mac, and remembers your choice.",
		"/ filters the grid; a shows all bus activity; m1max's sync health is in the header.",
		"A macOS notification when something new needs you (AGENT_BUS_TUI_NOTIFY=0 turns it off).",
	}},
}

type welcomeKind int

const (
	welcomeFirst welcomeKind = iota
	welcomeNews
)

// startupWelcome decides what, if anything, opens at launch.
func startupWelcome() (welcomeKind, bool) {
	p, ok := loadPrefs()
	switch {
	case !ok || !p.Welcomed:
		return welcomeFirst, true
	case version != "dev" && p.SeenVersion != version && notesFor(version) != nil:
		return welcomeNews, true
	}
	return 0, false
}

func notesFor(v string) []string {
	v = strings.TrimPrefix(v, "v")
	for _, n := range whatsNew {
		if n.version == v {
			return n.notes
		}
	}
	return nil
}

func markWelcomed() {
	savePrefs(func(p *prefs) { p.Welcomed = true; p.SeenVersion = version })
}

// installedAgents is which agent tools are on this Mac.
func installedAgents() []string {
	var out []string
	for _, t := range []struct{ bin, name string }{{"claude", "Claude Code"}, {"opencode", "OpenCode"}, {"codex", "Codex"}, {"grok", "Grok"}} {
		if _, err := exec.LookPath(t.bin); err == nil {
			out = append(out, t.name)
		}
	}
	for _, app := range []string{"Claude", "Codex"} {
		if _, err := os.Stat("/Applications/" + app + ".app"); err == nil {
			out = append(out, app+" app")
		}
	}
	return out
}

func (m model) welcomeView() string {
	var lines []string
	if m.welcome == welcomeNews {
		lines = append(lines, sAccent.Render("What's new in agent-bus "+strings.TrimPrefix(version, "v")), "")
		for _, n := range notesFor(version) {
			lines = append(lines, lipgloss.NewStyle().Width(min(76, m.w-12)).Render("• "+n))
		}
	} else {
		lines = append(lines, sAccent.Render("Welcome to agent-bus"), "",
			"One screen for every coding agent on this Mac (and your linked Macs):",
			"who needs you, who is doing what, and who is idle.", "")
		agents := installedAgents()
		if len(agents) == 0 {
			agents = []string{"none found on PATH"}
		}
		lines = append(lines, sDim.Render("Agents here    ")+strings.Join(agents, ", "))
		seated := 0
		if m.snap != nil {
			seated = len(m.snap.Seats)
		}
		wired := lipgloss.NewStyle().Foreground(cGood).Render("yes, " + plural(seated, "agent") + " on the bus")
		if seated == 0 {
			wired = lipgloss.NewStyle().Foreground(cWarn).Render("no agents yet: run agent-bus hooks, then start one")
		}
		lines = append(lines, sDim.Render("Wired in       ")+wired)
		if m.snap != nil && len(m.snap.Peers) > 0 {
			var names []string
			for _, p := range m.snap.Peers {
				names = append(names, p.Name)
			}
			lines = append(lines, sDim.Render("Linked Macs    ")+strings.Join(names, ", "))
		}
		lines = append(lines, "",
			"  1-9      go to an agent that needs you (numbered in the header)",
			"  enter    its panel; enter again brings its app to the front",
			"  /        filter       g  group by        a  all activity",
			"  O        ask an agent to offboard        ?  every key")
	}
	lines = append(lines, "", sDim.Render("any key to start · w shows this again"))
	return lipgloss.Place(m.w, m.h, lipgloss.Center, lipgloss.Center,
		lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cAccent).Padding(1, 3).Render(strings.Join(lines, "\n")))
}
