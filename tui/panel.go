package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// panelView is the side panel: who the agent is and what it needs from you.
func (m model) panelView(w, h int) string {
	t := m.panel
	s := t.seat
	inner := w - 4
	var b []string

	// Who: the bot beside its name, what it's on, and where.
	info := []string{
		lipgloss.NewStyle().Bold(true).Foreground(cText).Render(friendlyName(s.Addr)),
		sDim.Render(fit(clean(s.Addr), inner-12)),
	}
	if on := workingOn(s); on != "" {
		info = append(info, sDim.Render(fit(clean(on), inner-12)))
	}
	where := ""
	switch {
	case t.gone:
		where = lipgloss.NewStyle().Foreground(cWarn).Render("not running")
	default:
		where = "seen " + ago(m.snap.Now, s.Epoch) + " ago"
		if t.peer != "" {
			where = "on " + t.peer + " · " + where
		}
		where = sDim.Render(where)
	}
	info = append(info, where)
	head := lipgloss.JoinHorizontal(lipgloss.Top, avatar(s), "  ", strings.Join(info, "\n"))
	b = append(b, head, "")
	if d := m.doing(s); d != "" {
		label := "Focus"
		if strings.TrimSpace(s.Focus) == "" {
			label = "Session"
		}
		b = append(b, sDim.Render(label), lipgloss.NewStyle().Width(inner).Render(d), "")
	}
	if svc := m.servicesFor(s); len(svc) > 0 {
		b = append(b, sDim.Render("Running"))
		for _, x := range svc {
			b = append(b, lipgloss.NewStyle().Foreground(cGood).Render(fmt.Sprintf("  :%-6d", x.Port))+sDim.Render(fit(clean(x.Cmd)+"  pid "+fmt.Sprint(x.PID), inner-10)))
		}
		b = append(b, "")
	}

	ns := m.panelNeeds()
	if len(ns) == 0 {
		b = append(b, sDim.Render("Nothing waiting on you."), "", sDim.Render("c or enter: chat with it"))
	} else {
		title := fmt.Sprintf("Waiting on you · %d", len(ns))
		b = append(b, lipgloss.NewStyle().Foreground(cBad).Bold(true).Render(title), "")
		for i, n := range ns {
			line := sDim.Render(fit(ago(m.snap.Now, n.Epoch), 4)) + " " + kindStyle(n.State).Render(n.State) + "  " + clean(n.Subject)
			if i == m.panelSel {
				line = sSel.Render(fit("› "+ansiStrip(line), inner))
			} else {
				line = "  " + fit(line, inner-2)
			}
			b = append(b, line)
		}
		if n, ok := m.selectedNeed(); ok {
			b = append(b, "", sDim.Render(strings.Repeat("─", inner)), "")
			body, have := m.bodies[n.ID]
			switch {
			case !have || body == "":
				body = sDim.Render("loading …")
			default:
				// The subject line is a markdown heading; show it as bold text.
				first, rest, _ := strings.Cut(clean2(body), "\n")
				first = lipgloss.NewStyle().Bold(true).Render(strings.TrimLeft(first, "# "))
				body = lipgloss.NewStyle().Width(inner).Render(first + "\n" + rest)
			}
			b = append(b, body)
		}
	}

	// The bottom: reply box, close confirmation, or nothing.
	var foot []string
	switch m.mode {
	case modeReply:
		foot = []string{sAccent.Render("Your answer to " + friendlyName(s.Addr)), m.input.View()}
	case modeConfirm:
		foot = []string{lipgloss.NewStyle().Foreground(cWarn).Render(fit("Close it?  y done · c canceled · n denied", inner))}
	case modeOpen:
		foot = append(foot, sAccent.Render("Open in…"))
		for i, it := range m.openItems {
			l := fmt.Sprintf("%d  %s", i+1, it.label)
			if i == m.openSel {
				foot = append(foot, sSel.Render(fit("› "+l, inner)))
			} else {
				foot = append(foot, "  "+fit(l, inner-2))
			}
		}
	}
	bodyH := h - 2 - len(foot)
	if len(foot) > 0 {
		bodyH--
	}
	lines := strings.Split(strings.Join(b, "\n"), "\n")
	if len(lines) > bodyH {
		lines = append(lines[:bodyH-1], sDim.Render("…"))
	}
	for len(lines) < bodyH {
		lines = append(lines, "")
	}
	if len(foot) > 0 {
		lines = append(lines, "")
		lines = append(lines, foot...)
	}
	bc := cAccent
	if len(ns) > 0 {
		bc = cBad
	}
	return lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(bc).
		Width(w-2).Height(h-2).Padding(0, 1).Render(strings.Join(lines, "\n"))
}

func ansiStrip(s string) string { return ansi.Strip(s) }
