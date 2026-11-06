package main

import (
	"bufio"
	"encoding/json"
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

// chatMsg is one line of a conversation between you (@lead) and one agent.
type chatMsg struct {
	ID    string
	Epoch int64
	Mine  bool
	State string
	Body  string
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
	Epoch   int64  `json:"epoch"`
	From    string `json:"from"`
	To      string `json:"to"`
	State   string `json:"state"`
	Subject string `json:"subject"`
	User    bool   `json:"user"`
}

func fromYou(r ledgerRow) bool { return r.User || strings.HasPrefix(r.From, "lead/") }
func toYou(to string) bool {
	return to == "@lead" || strings.HasPrefix(to, "lead/") || strings.HasPrefix(to, "shell/")
}

// loadChat reads the ledger (read-only) for messages between you and addr,
// with their bodies. The TUI never writes the bus; sending goes through the CLI.
func loadChat(bus, addr string) tea.Cmd {
	return func() tea.Msg {
		f, err := os.Open(bus + "/ledger.jsonl")
		if err != nil {
			return chatLoaded{addr: addr, err: err}
		}
		defer f.Close()
		var msgs []chatMsg
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1<<20), 16<<20)
		for sc.Scan() {
			line := sc.Bytes()
			if !strings.Contains(string(line), addr) {
				continue
			}
			var r ledgerRow
			if json.Unmarshal(line, &r) != nil || r.Kind != "msg" {
				continue
			}
			var mine bool
			switch {
			case r.To == addr && fromYou(r):
				mine = true
			case r.From == addr && toYou(r.To):
				mine = false
			default:
				continue
			}
			body := r.Subject
			if b, err := os.ReadFile(bus + "/msg/" + r.ID + ".md"); err == nil && len(b) > 0 {
				if len(b) > 8000 {
					b = append(b[:8000], []byte("\n…")...)
				}
				body = string(b)
			}
			msgs = append(msgs, chatMsg{ID: r.ID, Epoch: r.Epoch, Mine: mine, State: r.State, Body: body})
		}
		sort.SliceStable(msgs, func(i, j int) bool { return msgs[i].Epoch < msgs[j].Epoch })
		if len(msgs) > 200 {
			msgs = msgs[len(msgs)-200:]
		}
		return chatLoaded{addr: addr, msgs: msgs}
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
	m.input.Placeholder = "message " + s.Addr + " as you · enter sends · esc back"
	m.input.SetValue("")
	m.input.Width = m.w - 6
	m.input.Focus()
	m.chatView = viewport.New(m.w-4, m.chatHeight())
	m.chatView.SetContent(sDim.Render("loading …"))
	return tea.Batch(loadChat(m.snap.Bus, s.Addr), textinput.Blink)
}

func (m model) chatHeight() int {
	h := m.h - 6
	if h < 3 {
		h = 3
	}
	return h
}

func (m *model) renderChat() {
	w := m.w - 6
	if w < 20 {
		w = 20
	}
	bubbleW := w * 3 / 4
	var out []string
	if len(m.chatMsgs) == 0 {
		out = append(out, sDim.Render("No messages between you and "+clean(m.chatSeat.Addr)+" yet. Say something below."))
	}
	var lastDay string
	for _, c := range m.chatMsgs {
		t := time.Unix(c.Epoch, 0)
		if d := t.Format("Mon Jan 2"); d != lastDay {
			lastDay = d
			out = append(out, "", lipgloss.PlaceHorizontal(w, lipgloss.Center, sDim.Render("── "+d+" ──")))
		}
		body := strings.TrimSpace(clean2(c.Body))
		meta := t.Format("15:04")
		if c.State != "" && c.State != "fyi" {
			meta += " · " + c.State
		}
		if c.Mine {
			bub := lipgloss.NewStyle().Background(cSel).Foreground(cText).Padding(0, 1).Width(min(bubbleW, lipgloss.Width(body)+2)).MaxWidth(bubbleW).Render(body)
			out = append(out, lipgloss.PlaceHorizontal(w, lipgloss.Right, sDim.Render("you · "+meta)))
			out = append(out, lipgloss.PlaceHorizontal(w, lipgloss.Right, bub))
		} else {
			name := lipgloss.NewStyle().Foreground(colorFor(m.chatSeat)).Bold(true).Render(clean(m.chatSeat.Addr))
			bub := lipgloss.NewStyle().Border(lipgloss.NormalBorder(), false, false, false, true).
				BorderForeground(colorFor(m.chatSeat)).PaddingLeft(1).Width(bubbleW).Render(body)
			out = append(out, name+sDim.Render(" · "+meta), bub)
		}
	}
	m.chatView.Width, m.chatView.Height = m.w-4, m.chatHeight()
	content := strings.Join(out, "\n")
	// Newest at the bottom, like any chat: pad a short conversation down.
	if n := lipgloss.Height(content); n < m.chatHeight() {
		content = strings.Repeat("\n", m.chatHeight()-n) + content
	}
	m.input.Width = m.w - 6
	m.chatView.SetContent(content)
	m.chatView.GotoBottom()
}

func (m model) chatKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch k.String() {
	case "esc":
		m.mode = modeNormal
		m.input.Blur()
		return m, nil
	case "enter":
		v := strings.TrimSpace(m.input.Value())
		if v == "" {
			return m, nil
		}
		m.input.SetValue("")
		m.chatSending = true
		// Show it right away; the reload replaces it with the real row.
		m.chatMsgs = append(m.chatMsgs, chatMsg{Epoch: time.Now().Unix(), Mine: true, State: "sending…", Body: v})
		m.renderChat()
		return m, sendChat(m.chatSeat.Addr, v)
	case "pgup", "pgdown", "up", "down":
		if k.String() == "up" || k.String() == "down" {
			if m.input.Value() != "" {
				break
			}
		}
		var cmd tea.Cmd
		m.chatView, cmd = m.chatView.Update(k)
		return m, cmd
	}
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(k)
	return m, cmd
}

func (m model) chatScreen() string {
	s := m.chatSeat
	dot := lipgloss.NewStyle().Foreground(colorFor(s)).Render("●")
	where := clean(strings.Trim(s.Repo+" · "+s.Branch, " ·-"))
	if m.chatPeer != "" {
		where = "on " + m.chatPeer + " · " + where
	}
	title := " " + dot + " " + sAccent.Render(clean(s.Addr)) + sDim.Render("  "+where)
	body := lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cAccent).
		Width(m.w-2).Height(m.chatHeight()).Padding(0, 1).Render(m.chatView.View())
	prompt := sAccent.Render(" › ") + m.input.View()
	help := " enter sends as you · ↑↓ pgup pgdn scroll · esc back"
	if m.chatSending {
		help = " sending …"
	}
	if m.status != "" {
		help = " " + m.status
	}
	return lipgloss.JoinVertical(lipgloss.Left, title, body, prompt, sDim.Render(fit(help, m.w)))
}
