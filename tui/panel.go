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
	if a, ok := m.appOf(t); ok {
		info = append(info, "", lipgloss.NewStyle().Foreground(cAccent).Bold(true).Render("⏎ open "+a.Name))
	}
	head := lipgloss.JoinHorizontal(lipgloss.Top, avatar(s), "  ", strings.Join(info, "\n"))
	b = append(b, head, "")
	// What it is doing right now leads: that is what you came to see.
	b = append(b, m.nowLines(t, inner)...)
	ns := m.panelNeeds()
	if len(ns) == 0 {
		b = append(b, sDim.Render("Nothing waiting on you · c: its timeline"))
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
		if n, ok := m.selectedNeed(); ok && isLive(n) {
			app := "its window"
			if a, ok := m.appOf(t); ok {
				app = a.Name
			}
			b = append(b, "", sText.Render(fit("It stopped on a prompt in "+app+": a permission or a question.", inner)),
				sAccent.Render("⏎ go answer it there"))
		} else if n, ok := m.selectedNeed(); ok {
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

	if p := m.panelPorts(s); p != "" {
		b = append(b, "", sDim.Render("Ports  ")+lipgloss.NewStyle().Foreground(cGood).Width(inner-7).Render(p))
	}

	// The bottom: reply box, close confirmation, or nothing.
	var foot []string
	switch m.mode {
	case modeReply:
		foot = []string{sAccent.Render("Your answer to " + friendlyName(s.Addr)), m.input.View()}
	case modeConfirm:
		foot = []string{lipgloss.NewStyle().Foreground(cWarn).Render(fit("Close it?  y done · c canceled · n denied", inner))}
	case modeOffboard:
		foot = []string{offboardPrompt(friendlyName(s.Addr), inner)}
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

// nowLines: its state, its latest move, what you last asked it, and its focus.
func (m model) nowLines(t tile, inner int) []string {
	s := t.seat
	wrap := lipgloss.NewStyle().Width(inner)
	state := ""
	switch {
	case t.gone:
		state = "not running"
	case s.Activity == "working":
		state = lipgloss.NewStyle().Foreground(cGood).Render("● working")
	case s.Activity == "waiting":
		state = lipgloss.NewStyle().Foreground(cBad).Render("◐ waiting for you in its window")
	case s.Activity == "idle":
		state = sDim.Render("○ idle since " + ago(m.snap.Now, s.ActivityAt) + " ago")
	}
	if st := stageLabel(s.Stage); st != "" {
		if state != "" {
			state += sDim.Render(" · ")
		}
		state += sAccent.Render(st)
	}
	var b []string
	if state != "" {
		b = append(b, state, "")
	}
	n := m.now[s.Addr]
	if n.Doing != "" {
		b = append(b, sDim.Render("Latest"), wrap.Render(n.Doing), "")
	}
	if n.Asked != "" {
		b = append(b, sDim.Render("You asked"), wrap.Render(trunc(n.Asked, 240)), "")
	}
	if d := m.doing(s); d != "" {
		label := "Focus"
		if strings.TrimSpace(s.Focus) == "" {
			label = "Session"
		}
		b = append(b, sDim.Render(label), wrap.Render(d), "")
	}
	return b
}

func trunc(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n]) + "…"
	}
	return s
}

// panelPorts is its ports on one line, leaving out the Docker VM's, which
// every agent in a folder with containers would otherwise share.
func (m model) panelPorts(s Seat) string {
	var p []string
	for _, x := range m.servicesFor(s) {
		c := strings.ToLower(x.Cmd)
		if strings.Contains(c, "orbstack") || strings.Contains(c, "docker") || strings.Contains(c, "vpnkit") || strings.Contains(c, "com.docke") {
			continue
		}
		p = append(p, fmt.Sprintf(":%d %s", x.Port, clean(x.Cmd)))
	}
	return strings.Join(p, "  ")
}
