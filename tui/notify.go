package main

import (
	"os/exec"
	"strconv"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

// Left open all day, the TUI tells you (a macOS notification) when something
// new needs you, so you don't have to watch it. AGENT_BUS_TUI_NOTIFY=0 turns
// that off.

func notifyEnabled() bool { return strings.TrimSpace(getenv("AGENT_BUS_TUI_NOTIFY")) != "0" }

// newNeeds returns asks not seen before and records them; the first call only
// records, so starting the TUI doesn't replay the backlog.
func (m *model) newNeeds(first bool) []need {
	if m.notified == nil {
		m.notified = map[string]bool{}
	}
	var fresh []need
	for _, ns := range m.needs() {
		for _, n := range ns {
			if !m.notified[n.ID] {
				m.notified[n.ID] = true
				if !first {
					fresh = append(fresh, n)
				}
			}
		}
	}
	return fresh
}

func notifyCmd(ns []need) tea.Cmd {
	if len(ns) == 0 || !notifyEnabled() {
		return nil
	}
	title := friendlyName(ns[0].From) + " needs you"
	body := clean(strings.TrimLeft(ns[0].Subject, "# "))
	if len(ns) > 1 {
		title = strconv.Itoa(len(ns)) + " agents need you"
		body = friendlyName(ns[0].From) + ": " + body
	}
	q := func(s string) string { // an AppleScript string literal
		return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(s) + `"`
	}
	script := "display notification " + q(body) + " with title " + q(title) + " subtitle \"agent-bus\""
	return func() tea.Msg { _ = exec.Command("osascript", "-e", script).Run(); return nil }
}
