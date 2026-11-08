package main

import (
	"os"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// O asks an agent, as you, to offboard: hand on or close what it holds, then
// run `agent-bus offboard`. The agent answers, which closes the ask.

const offboardText = "# Please offboard\n\n" +
	"You look done here. Finish or hand on anything you're holding, then run " +
	"`agent-bus offboard` and hand on or close (with a reason) every item it lists. " +
	"Reply with one line on what you closed or handed on. No new work after that."

type offboardSent struct {
	name, out string
	err       error
}

func offboardCmd(addr string) tea.Cmd {
	return func() tea.Msg {
		cmd := exec.Command(cli(), "send", "--yes", "--to", addr, "--state", "question", "-m", offboardText)
		cmd.Env = append(os.Environ(), "AGENT_BUS_TOOL=lead")
		cmd.Stdin = os.Stdin
		out, err := cmd.CombinedOutput()
		return offboardSent{friendlyName(addr), strings.TrimSpace(string(out)), err}
	}
}

// startOffboard opens the agent's panel with a y/N question at the bottom.
func (m model) startOffboard() (tea.Model, tea.Cmd) {
	t, ok := m.selectedTile()
	if !ok {
		return m, nil
	}
	if t.off {
		m.setStatus(friendlyName(t.seat.Addr) + " has already offboarded")
		return m, nil
	}
	if t.gone {
		m.setStatus(friendlyName(t.seat.Addr) + " has exited; nothing to offboard")
		return m, nil
	}
	if t.peer != "" {
		m.setStatus(friendlyName(t.seat.Addr) + " is on " + t.peer + "; offboard it from that Mac")
		return m, nil
	}
	mm, cmd := m.openPanel()
	m = mm.(model)
	m.mode = modeOffboard
	return m, cmd
}

func (m model) offboardKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	m.mode = modePanel
	if k.String() == "y" {
		m.setStatus("asking " + friendlyName(m.panel.seat.Addr) + " to offboard…")
		return m, offboardCmd(m.panel.seat.Addr)
	}
	m.setStatus("not sent")
	return m, nil
}

func (m model) offboardDone(msg offboardSent) model {
	if msg.err != nil {
		m.setStatus("✗ not sent: " + firstLine(msg.out))
		return m
	}
	note := "sent"
	for _, l := range strings.Split(msg.out, "\n") {
		if strings.HasPrefix(l, "delivery") {
			if i := strings.Index(l, " — "); i >= 0 {
				note = clean(l[i+len(" — "):])
			} else if i := strings.Index(l, ": "); i >= 0 {
				note = clean(l[i+2:])
			}
		}
	}
	m.setStatus("asked " + msg.name + " to offboard · " + note)
	return m
}

func offboardPrompt(name string, w int) string {
	return lipgloss.NewStyle().Foreground(cWarn).Render(fit("Ask "+name+" to offboard?  y yes · any other key no", w))
}
