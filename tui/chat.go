package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"sort"
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
	Kind    string // msg, resolve, decision; asked, said, tool (its own session)
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
func loadChat(bus string, seat Seat) tea.Cmd {
	addr := seat.Addr
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
				if addr != "" && r.By != addr && !ours {
					continue
				}
				if subj == "" {
					subj = r.Msg
				}
				out = append(out, chatMsg{ID: r.Msg, Epoch: r.Epoch, Kind: "resolve", From: r.By, Subject: subj, Reason: r.Reason,
					Mine: strings.HasPrefix(r.By, "lead/")})
				continue
			case addr != "" && !strings.Contains(line, addr):
				continue
			}
			if json.Unmarshal([]byte(line), &r) != nil {
				continue
			}
			switch r.Kind {
			case "msg":
				if addr != "" && r.From != addr && !addressedTo(r.To, addr) {
					continue
				}
				mine[r.ID] = r.Subject
				out = append(out, chatMsg{ID: r.ID, Epoch: r.Epoch, Kind: "msg", From: r.From, To: r.To, State: r.State,
					Subject: r.Subject, Close: r.Close, Mine: fromYou(r), ToYou: toYou(r.To)})
			case "decision":
				if addr != "" && r.By != addr {
					continue
				}
				out = append(out, chatMsg{ID: r.ID, Epoch: r.Epoch, Kind: "decision", From: r.By, Subject: r.Text, Body: r.Why})
			}
		}
		if len(out) > 400 {
			out = out[len(out)-400:]
		}
		// Its own session: what you asked, what it said, the tools it ran.
		if seat.Tool == "claude" && seat.Session != "" {
			out = append(out, claudeLog(seat.Session)...)
			sort.SliceStable(out, func(i, j int) bool { return out[i].Epoch < out[j].Epoch })
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
	return tea.Batch(loadChat(m.snap.Bus, s), textinput.Blink)
}

// openActivity is the same screen over every agent: the whole bus, newest at
// the bottom, read-only.
func (m *model) openActivity() tea.Cmd {
	m.mode = modeChat
	m.chatSeat, m.chatPeer = Seat{}, ""
	m.chatMsgs = nil
	m.chatStamp = ""
	m.chatNote = ""
	m.chatSel, m.chatFollow = 0, true
	m.input.SetValue("")
	m.input.Blur()
	m.chatView = viewport.New(m.w/2, m.chatHeight())
	return loadChat(m.snap.Bus, Seat{})
}

func (m model) allActivity() bool { return m.mode == modeChat && m.chatSeat.Addr == "" }

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
		if m.allActivity() || c.From != m.chatSeat.Addr {
			who = party(c.From) + " closed"
		}
		return "✓ " + who, lipgloss.NewStyle().Foreground(cGood)
	case "decision":
		if m.allActivity() {
			return "◆ " + party(c.From) + " decided", sAccent
		}
		return "◆ decided", sAccent
	}
	if m.allActivity() {
		if c.Mine {
			return "you → " + party(c.To), lipgloss.NewStyle().Foreground(cAccent).Bold(true)
		}
		return party(c.From) + " → " + party(c.To), sText
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

// renderChat lays the whole log out, full width, every entry in full.
func (m *model) renderChat() {
	w := m.w - 4
	m.chatView.Width, m.chatView.Height = w, m.chatHeight()
	m.input.Width = m.w - 6
	if len(m.chatMsgs) == 0 {
		msg := "Nothing yet from or to " + friendlyName(m.chatSeat.Addr) + ". Say something below."
		if m.allActivity() {
			msg = "Nothing on the bus yet."
		}
		m.chatView.SetContent(sDim.Render(msg))
		return
	}
	var b []string
	var lastDay string
	for _, c := range m.chatMsgs {
		t := time.Unix(c.Epoch, 0)
		if d := t.Format("Mon Jan 2"); d != lastDay {
			lastDay = d
			b = append(b, "", sDim.Render("── "+d+" "+strings.Repeat("─", max(0, w-len(d)-4))))
		}
		b = append(b, m.logEntry(c, w)...)
	}
	m.chatView.SetContent(strings.Join(b, "\n"))
	if m.chatFollow {
		m.chatView.GotoBottom()
	}
}

// logEntry is one entry: a header line (time, who, what kind) and its text.
func (m model) logEntry(c chatMsg, w int) []string {
	at := sDim.Render(time.Unix(c.Epoch, 0).Format("15:04") + "  ")
	body := lipgloss.NewStyle().Width(w - 7).MarginLeft(7)
	text := strings.TrimSpace(c.Body)
	if text == "" {
		text = c.Subject
	}
	text = clean2(text)
	switch c.Kind {
	case "tool":
		// One dim line: tools are the texture, not the story.
		return []string{at + sDim.Render(fit("▸ "+oneLine(c.Subject), w-7))}
	case "asked":
		return []string{"", at + lipgloss.NewStyle().Foreground(cAccent).Bold(true).Render("you"),
			body.Render(lipgloss.NewStyle().Foreground(cAccent).Render(capLines(text, 12)))}
	case "said":
		name := lipgloss.NewStyle().Foreground(lipgloss.Color(avatarColor(toolOf(m.chatSeat)))).Bold(true).Render(friendlyName(m.chatSeat.Addr))
		return []string{"", at + name, body.Render(capLines(text, 30))}
	case "resolve":
		label, st := m.rowLabel(c)
		return []string{at + st.Render(label+" "+c.Reason) + sDim.Render("  "+fit(oneLine(c.Subject), w-30))}
	case "decision":
		label, st := m.rowLabel(c)
		return []string{"", at + st.Render(label), body.Render(text)}
	}
	label, st := m.rowLabel(c)
	state := c.State
	if c.Close != "" {
		state = "closed " + c.Close
	}
	head := at + st.Bold(true).Render(label) + "  " + kindStyle(c.State).Render(state) + sDim.Render("  on the bus")
	return []string{"", head, body.Render(capLines(text, 30))}
}

func capLines(s string, n int) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	if len(lines) > n {
		lines = append(lines[:n], "…")
	}
	return strings.Join(lines, "\n")
}

func (m model) chatKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	scrolled := func() (tea.Model, tea.Cmd) {
		m.chatFollow = m.chatView.AtBottom()
		return m, nil
	}
	switch k.String() {
	case "esc":
		m.mode = modeNormal
		m.input.Blur()
		return m, nil
	case "up":
		m.chatView.LineUp(1)
		return scrolled()
	case "down":
		m.chatView.LineDown(1)
		return scrolled()
	case "pgup", "shift+up", "ctrl+u":
		m.chatView.HalfPageUp()
		return scrolled()
	case "pgdown", "shift+down", "ctrl+d":
		m.chatView.HalfPageDown()
		return scrolled()
	case "home":
		m.chatView.GotoTop()
		return scrolled()
	case "end":
		m.chatView.GotoBottom()
		return scrolled()
	case "q":
		if m.allActivity() {
			m.mode = modeNormal
			return m, nil
		}
	case "enter":
		if m.allActivity() {
			return m, nil
		}
		v := strings.TrimSpace(m.input.Value())
		if v == "" {
			return m, nil
		}
		m.input.SetValue("")
		m.chatSending = true
		m.chatFollow = true
		return m, sendChat(m.chatSeat.Addr, v)
	}
	if m.allActivity() {
		return m, nil
	}
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(k)
	return m, cmd
}

func (m model) chatScreen() string {
	s := m.chatSeat
	// Header: who, what it's on, where, when.
	name := lipgloss.NewStyle().Foreground(lipgloss.Color(avatarColor(toolOf(s)))).Bold(true).Render(friendlyName(s.Addr))
	parts := []string{name, sDim.Render(clean(s.Addr))}
	if d := m.doing(s); d != "" {
		parts = append(parts, d)
	}
	if m.chatPeer != "" {
		parts = append(parts, sDim.Render("on "+m.chatPeer))
	}
	if dot := activityDot(s); dot != "" {
		parts = append(parts, dot+sDim.Render(s.Activity))
	} else {
		parts = append(parts, sDim.Render("seen "+ago(m.snap.Now, s.Epoch)+" ago"))
	}
	title := " " + fit(strings.Join(parts, sDim.Render(" · ")), m.w-2)
	if m.allActivity() {
		title = " " + sAccent.Render("All activity") + sDim.Render(fmt.Sprintf(" · every message, close and decision on the bus · %d", len(m.chatMsgs)))
	}
	box := lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cAccent).
		Width(m.w-2).Height(m.chatHeight()).Padding(0, 1).Render(m.chatView.View())

	prompt := sAccent.Render(" › ") + m.input.View()
	help := " ↑↓ scroll · pgup pgdn · home end · enter sends as you (over the bus) · esc back"
	if m.allActivity() {
		prompt = sDim.Render(" to message an agent, open its log with c")
		help = " ↑↓ scroll · pgup pgdn · home end · esc back"
	}
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
	return lipgloss.JoinVertical(lipgloss.Left, title, box, prompt, foot)
}
