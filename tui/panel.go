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

	b = append(b, m.panelHead(t, inner)...)
	b = append(b, m.panelContext(t, inner)...)

	ns := m.panelNeeds()
	if len(ns) > 0 {
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

// panelHead is who it is and what state it's in.
func (m model) panelHead(t tile, inner int) []string {
	s := t.seat
	head := lipgloss.NewStyle().Bold(true).Foreground(colorFor(s)).Render(friendlyName(s.Addr)) + sDim.Render("  "+clean(s.Addr))
	var meta []string
	if tk := ticketOf(s); tk != "" {
		meta = append(meta, sAccent.Render(tk))
	}
	if s.Branch != "" && s.Branch != "-" {
		meta = append(meta, clean(s.Branch))
	}
	if t.peer != "" {
		meta = append(meta, "on "+t.peer)
	}
	if s.Pid > 0 {
		meta = append(meta, fmt.Sprintf("pid %d", s.Pid))
	}
	out := []string{fit(head, inner), sDim.Render(fit(strings.Join(meta, " · "), inner))}

	c, ok := m.ctx[s.Addr]
	var line, tone string
	switch {
	case t.gone:
		line, tone = "not running", "warn"
	case ok && c.State != "":
		line, tone = c.stateLine(m.snap.Now)
	case toolOf(s) != "claude":
		line, tone = "seen "+ago(m.snap.Now, s.Epoch)+" ago · "+toolOf(s)+": bus only, no transcript to read", "dim"
	default:
		line, tone = "seen "+ago(m.snap.Now, s.Epoch)+" ago · no transcript found", "dim"
	}
	out = append(out, toneStyle(tone).Bold(tone != "dim").Render(fit(line, inner)))
	if ok && c.CtxUsed > 0 {
		pct := c.ctxPct()
		win, guess := c.window()
		of := "of " + kTokens(win)
		if guess {
			of += "?"
		}
		l := toneStyle(ctxTone(pct)).Render(meter(pct, 10)) + " " + sText.Render(fmt.Sprintf("%s %s (%d%%)", kTokens(c.CtxUsed), of, pct))
		var more []string
		if c.Model != "" {
			more = append(more, strings.TrimPrefix(c.Model, "claude-"))
		}
		if c.Compacts > 0 {
			more = append(more, fmt.Sprintf("compacted %d×", c.Compacts))
		}
		if len(more) > 0 {
			l += sDim.Render(" · " + strings.Join(more, " · "))
		}
		out = append(out, sDim.Render("context ")+fit(l, inner-8))
	}
	return out
}

func toneStyle(tone string) lipgloss.Style {
	switch tone {
	case "good":
		return lipgloss.NewStyle().Foreground(cGood)
	case "warn":
		return lipgloss.NewStyle().Foreground(cWarn)
	case "bad":
		return lipgloss.NewStyle().Foreground(cBad)
	}
	return sDim
}

// panelContext is what the row can't show: its activity over the last hour,
// what it was asked and last said, its code, and its ports.
func (m model) panelContext(t tile, inner int) []string {
	s := t.seat
	rule := sDim.Render(strings.Repeat("─", inner))
	out := []string{rule}
	c, ok := m.ctx[s.Addr]
	if ok && c.OK {
		top := 0
		for _, tr := range c.Strip {
			for _, n := range tr {
				top = max(top, n)
			}
		}
		bars := []rune(" ▁▂▃▄▅▆▇█")
		if top == 0 {
			out = append(out, sDim.Render("no tool calls in the last hour"))
		}
		for k, tr := range c.Strip {
			if top == 0 {
				break
			}
			var b strings.Builder
			for _, n := range tr {
				if n == 0 {
					b.WriteRune(' ')
				} else {
					b.WriteRune(bars[1+min(7, (n*8-1)/top)])
				}
			}
			out = append(out, sDim.Render(fmt.Sprintf("%-5s", trackNames[k]))+lipgloss.NewStyle().Foreground(cAccent).Render(b.String())+sDim.Render("▏"))
		}
		if top > 0 {
			out = append(out, sDim.Render("     60m ago"+strings.Repeat(" ", stripBins-10)+"now"))
		}
		sum := fmt.Sprintf("     %d edits · %d reads · %d bash · %d messages", c.Counts[trackEdit], c.Counts[trackRead], c.Counts[trackBash], c.Counts[trackTalk])
		if c.Errors > 0 {
			sum += fmt.Sprintf(" · %d tool errors", c.Errors)
		}
		out = append(out, sDim.Render(fit(sum, inner)), rule)
		say := func(label string, e tEvent) {
			if strings.TrimSpace(e.Text) == "" {
				return
			}
			lines := wrapLines(clean(e.Text), inner-7, 3)
			for i, l := range lines {
				lab := strings.Repeat(" ", 7)
				if i == 0 {
					lab = fmt.Sprintf("%-7s", label)
				}
				out = append(out, sDim.Render(lab)+sText.Render(l))
			}
		}
		say("asked", c.Asked)
		say("said", c.Said)
		if c.State == stateTool {
			say("waits", tEvent{Text: c.Pending.Who + ": " + c.Pending.Text})
		}
		for _, tl := range c.Tools {
			out = append(out, sDim.Render(fit(fmt.Sprintf("  %-5s %s %s", ago(m.snap.Now, tl.Epoch), tl.Who, tl.Text), inner)))
		}
		out = append(out, rule)
	} else if d := m.doing(s); d != "" {
		out = append(out, sDim.Render("focus"))
		out = append(out, wrapLines(d, inner, 3)...)
		out = append(out, rule)
	}

	if t.peer == "" && s.Cwd != "" {
		g, have := m.git[s.Addr]
		switch {
		case !have:
			out = append(out, sDim.Render("git   reading …"))
		case g.Err != "":
			out = append(out, sDim.Render("git   "+g.Err))
		default:
			st := fmt.Sprintf("%s ↑%d ↓%d", clean(g.Branch), g.Ahead, g.Behind)
			dirty := sDim.Render(" · clean")
			if g.Dirty > 0 {
				dirty = lipgloss.NewStyle().Foreground(cWarn).Render(fmt.Sprintf(" · %d uncommitted", g.Dirty))
			}
			out = append(out, sDim.Render("git   ")+sText.Render(st)+dirty)
			if g.Last != "" {
				out = append(out, sDim.Render(fit("      "+clean(g.Last), inner)))
			}
			if g.PR != nil {
				ck, tone := g.PR.checks()
				line := sDim.Render(fmt.Sprintf("%-6s", strings.ToLower(g.PR.Kind))) + sText.Render(g.PR.ref()+" "+strings.ToLower(g.PR.State))
				if ck != "" {
					line += sDim.Render(" · ") + toneStyle(tone).Render(ck)
				}
				if g.PR.Review != "" {
					line += sDim.Render(" · " + strings.ToLower(strings.ReplaceAll(g.PR.Review, "_", " ")))
				}
				out = append(out, line)
			}
		}
	}
	if svc := m.servicesFor(s); len(svc) > 0 {
		out = append(out, sDim.Render("ports ")+lipgloss.NewStyle().Foreground(cGood).Render(fit(ports(svc), inner-6)))
	}
	return append(out, "")
}
