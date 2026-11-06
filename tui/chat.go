package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// The agent screen: a timeline of everything an agent sent, received, closed
// or decided (with you and with other agents), the selected entry in full,
// and a box to message it as you.

type chatMsg struct {
	ID      string
	Epoch   int64
	Kind    string // msg, resolve, decision
	From    string
	To      string
	State   string
	Subject string
	Close   string
	Reason  string
	Mine    bool // you sent it
	ToYou   bool // sent to you
	Body    string
}

type chatLoaded struct {
	addr string
	msgs []chatMsg
	err  error
}

type chatSent struct {
	out string
	err error
}

type ledgerRow struct {
	Kind    string `json:"kind"`
	ID      string `json:"id"`
	Msg     string `json:"msg"`
	Epoch   int64  `json:"epoch"`
	From    string `json:"from"`
	To      string `json:"to"`
	By      string `json:"by"`
	State   string `json:"state"`
	Subject string `json:"subject"`
	Close   string `json:"close"`
	Reason  string `json:"reason"`
	Text    string `json:"text"`
	Why     string `json:"why"`
	User    bool   `json:"user"`
}

func fromYou(r ledgerRow) bool { return r.User || strings.HasPrefix(r.From, "lead/") }
func toYou(to string) bool {
	return to == "@lead" || strings.HasPrefix(to, "lead/") || strings.HasPrefix(to, "shell/")
}

func addressedTo(to, addr string) bool {
	if to == addr {
		return true
	}
	for _, t := range strings.Split(to, ",") {
		if strings.TrimSpace(t) == addr {
			return true
		}
	}
	return false
}

// loadChat reads the ledger (read-only) for one agent's timeline.
func loadChat(bus, addr string) tea.Cmd {
	return func() tea.Msg {
		f, err := os.Open(bus + "/ledger.jsonl")
		if err != nil {
			return chatLoaded{addr: addr, err: err}
		}
		defer f.Close()
		var out []chatMsg
		mine := map[string]string{} // ids of its items -> subject
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1<<20), 16<<20)
		for sc.Scan() {
			line := sc.Text()
			var r ledgerRow
			switch {
			case strings.Contains(line, `"kind":"resolve"`):
				if json.Unmarshal([]byte(line), &r) != nil {
					continue
				}
				subj, ours := mine[r.Msg]
				if r.By != addr && !ours {
					continue
				}
				if subj == "" {
					subj = r.Msg
				}
				out = append(out, chatMsg{ID: r.Msg, Epoch: r.Epoch, Kind: "resolve", From: r.By, Subject: subj, Reason: r.Reason,
					Mine: strings.HasPrefix(r.By, "lead/")})
				continue
			case !strings.Contains(line, addr):
				continue
			}
			if json.Unmarshal([]byte(line), &r) != nil {
				continue
			}
			switch r.Kind {
			case "msg":
				if r.From != addr && !addressedTo(r.To, addr) {
					continue
				}
				mine[r.ID] = r.Subject
				out = append(out, chatMsg{ID: r.ID, Epoch: r.Epoch, Kind: "msg", From: r.From, To: r.To, State: r.State,
					Subject: r.Subject, Close: r.Close, Mine: fromYou(r), ToYou: toYou(r.To)})
			case "decision":
				if r.By != addr {
					continue
				}
				out = append(out, chatMsg{ID: r.ID, Epoch: r.Epoch, Kind: "decision", From: r.By, Subject: r.Text, Body: r.Why})
			}
		}
		if len(out) > 400 {
			out = out[len(out)-400:]
		}
		for i := range out {
			if out[i].Kind != "msg" {
				continue
			}
			if b, err := os.ReadFile(bus + "/msg/" + out[i].ID + ".md"); err == nil && len(b) > 0 {
				if len(b) > 12000 {
					b = append(b[:12000], []byte("\n…")...)
				}
				out[i].Body = string(b)
			}
		}
		return chatLoaded{addr: addr, msgs: out}
	}
}

// sendChat sends as you, through `agent-bus send`, so the agent is told the
// message is from its user. send needs your terminal on stdin.
func sendChat(addr, text string) tea.Cmd {
	return func() tea.Msg {
		cmd := exec.Command(cli(), "send", "--yes", "--to", addr, "--state", "question", "-m", text)
		cmd.Env = append(os.Environ(), "AGENT_BUS_TOOL=lead")
		cmd.Stdin = os.Stdin
		out, err := cmd.CombinedOutput()
		return chatSent{out: strings.TrimSpace(string(out)), err: err}
	}
}

func (m *model) openChat(s Seat, peer string) tea.Cmd {
	m.mode = modeChat
	m.chatSeat, m.chatPeer = s, peer
	m.chatMsgs = nil
	m.chatStamp = ""
	m.chatNote = ""
	m.chatSel, m.chatFollow = 0, true
	m.input.Placeholder = "message " + friendlyName(s.Addr) + " as you · enter sends"
	m.input.SetValue("")
	m.input.Width = m.w - 6
	m.input.Focus()
	m.chatView = viewport.New(m.w/2, m.chatHeight())
	return tea.Batch(loadChat(m.snap.Bus, s.Addr), textinput.Blink)
}

func (m model) chatHeight() int { return max(3, m.h-6) }

// party names the other side of a message: you, a broadcast, or an agent.
func party(addr string) string {
	switch {
	case addr == "":
		return "?"
	case toYou(addr):
		return "you"
	case strings.HasPrefix(addr, "@"):
		return addr
	case strings.Contains(addr, ","):
		return fmt.Sprintf("%d agents", len(strings.Split(addr, ",")))
	}
	return friendlyName(addr)
}

func (m model) rowLabel(c chatMsg) (string, lipgloss.Style) {
	switch c.Kind {
	case "resolve":
		who := "closed"
		if c.From != m.chatSeat.Addr {
			who = party(c.From) + " closed"
		}
		return "✓ " + who, lipgloss.NewStyle().Foreground(cGood)
	case "decision":
		return "◆ decided", sAccent
	}
	if c.From == m.chatSeat.Addr {
		return "→ " + party(c.To), sText
	}
	if c.Mine {
		return "← you", lipgloss.NewStyle().Foreground(cAccent).Bold(true)
	}
	return "← " + party(c.From), sText
}

func when(epoch int64) string {
	t := time.Unix(epoch, 0)
	if time.Since(t) < 20*time.Hour && t.Day() == time.Now().Day() {
		return t.Format("15:04")
	}
	return t.Format("Jan 2")
}

// renderChat refreshes the detail pane for the selected entry.
func (m *model) renderChat() {
	_, dw := m.chatWidths()
	m.chatView.Width, m.chatView.Height = dw-4, m.chatHeight()-2
	m.input.Width = m.w - 6
	if m.chatSel < 0 || m.chatSel >= len(m.chatMsgs) {
		m.chatView.SetContent(sDim.Render("Nothing on the bus from or to " + friendlyName(m.chatSeat.Addr) + " yet.\nSay something below."))
		return
	}
	c := m.chatMsgs[m.chatSel]
	w := dw - 6
	var b []string
	label, st := m.rowLabel(c)
	b = append(b, st.Bold(true).Render(label))
	meta := time.Unix(c.Epoch, 0).Format("Mon Jan 2 15:04")
	if c.State != "" {
		meta += " · " + c.State
	}
	if c.Close != "" {
		meta += " · closes its parent (" + c.Close + ")"
	}
	if c.Reason != "" {
		meta += " · " + c.Reason
	}
	b = append(b, sDim.Render(meta))
	if c.Kind == "msg" {
		b = append(b, sDim.Render(fit(clean(c.From)+" → "+clean(c.To), w)))
	}
	b = append(b, "")
	body := strings.TrimSpace(c.Body)
	if body == "" {
		body = c.Subject
	}
	first, rest, _ := strings.Cut(clean2(body), "\n")
	b = append(b, lipgloss.NewStyle().Bold(true).Width(w).Render(strings.TrimLeft(first, "# ")))
	if strings.TrimSpace(rest) != "" {
		b = append(b, lipgloss.NewStyle().Width(w).Render(rest))
	}
	if c.ID != "" {
		b = append(b, "", sDim.Render(c.ID))
	}
	m.chatView.SetContent(strings.Join(b, "\n"))
	m.chatView.GotoTop()
}

func (m model) chatWidths() (int, int) {
	lw := m.w * 55 / 100
	return lw, m.w - lw
}

func (m model) chatKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	move := func(d int) (tea.Model, tea.Cmd) {
		n := len(m.chatMsgs)
		if n == 0 {
			return m, nil
		}
		m.chatSel = max(0, min(n-1, m.chatSel+d))
		m.chatFollow = m.chatSel == n-1
		m.renderChat()
		return m, nil
	}
	switch k.String() {
	case "esc":
		m.mode = modeNormal
		m.input.Blur()
		return m, nil
	case "up":
		return move(-1)
	case "down":
		return move(1)
	case "pgup":
		return move(-10)
	case "pgdown":
		return move(10)
	case "home":
		return move(-1 << 20)
	case "end":
		return move(1 << 20)
	case "shift+up", "ctrl+u":
		m.chatView.HalfPageUp()
		return m, nil
	case "shift+down", "ctrl+d":
		m.chatView.HalfPageDown()
		return m, nil
	case "enter":
		v := strings.TrimSpace(m.input.Value())
		if v == "" {
			return m, nil
		}
		m.input.SetValue("")
		m.chatSending = true
		m.chatFollow = true
		return m, sendChat(m.chatSeat.Addr, v)
	}
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(k)
	return m, cmd
}

func (m model) chatScreen() string {
	s := m.chatSeat
	lw, dw := m.chatWidths()
	h := m.chatHeight()

	// Header: who, what it's on, where, when.
	name := lipgloss.NewStyle().Foreground(lipgloss.Color(avatarColor(toolOf(s)))).Bold(true).Render(friendlyName(s.Addr))
	parts := []string{name, sDim.Render(clean(s.Addr))}
	if d := m.doing(s); d != "" {
		parts = append(parts, d)
	}
	if m.chatPeer != "" {
		parts = append(parts, sDim.Render("on "+m.chatPeer))
	}
	seen := "seen " + ago(m.snap.Now, s.Epoch) + " ago"
	if s.Epoch > 0 && m.snap.Now-s.Epoch > 30*60 {
		parts = append(parts, lipgloss.NewStyle().Foreground(cWarn).Render(seen+" · may not be running"))
	} else {
		parts = append(parts, sDim.Render(seen))
	}
	title := " " + fit(strings.Join(parts, sDim.Render(" · ")), m.w-2)

	// The timeline, newest at the bottom, scrolled to the selection.
	inner := lw - 4
	rows := h - 2
	var lines []string
	if len(m.chatMsgs) == 0 {
		lines = append(lines, sDim.Render("No activity yet."))
	}
	off := 0
	if m.chatSel >= rows {
		off = m.chatSel - rows + 1
	}
	for i := off; i < len(m.chatMsgs) && len(lines) < rows; i++ {
		c := m.chatMsgs[i]
		label, st := m.rowLabel(c)
		state := c.State
		if c.Close != "" {
			state = "closed " + c.Close
		}
		if c.Kind == "resolve" {
			state = c.Reason
		}
		row := sDim.Render(fmt.Sprintf("%-6s", when(c.Epoch))) + st.Render(fit(label, 18)) + " " +
			kindStyle(c.State).Render(fit(state, 12)) + " " + fit(clean(strings.TrimLeft(c.Subject, "# ")), max(4, inner-38))
		if i == m.chatSel {
			row = sSel.Render(fit(ansiStrip(row), inner))
		}
		lines = append(lines, row)
	}
	for len(lines) < rows {
		lines = append([]string{""}, lines...) // newest sits at the bottom
	}
	list := lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cAccent).
		Width(lw-2).Height(h).Padding(0, 1).Render(strings.Join(lines, "\n"))
	detail := lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cDim).
		Width(dw-2).Height(h).Padding(0, 1).Render(m.chatView.View())

	prompt := sAccent.Render(" › ") + m.input.View()
	help := " ↑↓ timeline · pgup pgdn · shift+↑↓ scroll entry · enter sends as you · esc back"
	foot := sDim.Render(fit(help, m.w))
	switch {
	case m.chatSending:
		foot = sDim.Render(" sending …")
	case m.status != "":
		foot = sDim.Render(fit(" "+m.status, m.w))
	case m.chatNote != "":
		st := sDim
		if strings.Contains(m.chatNote, "not running") || strings.Contains(m.chatNote, "exited") || strings.Contains(m.chatNote, "waits") {
			st = lipgloss.NewStyle().Foreground(cWarn)
		}
		foot = st.Render(fit(" delivery: "+m.chatNote, m.w))
	}
	return lipgloss.JoinVertical(lipgloss.Left, title, lipgloss.JoinHorizontal(lipgloss.Top, list, detail), prompt, foot)
}
