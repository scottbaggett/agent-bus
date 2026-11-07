// agent-bus-tui: a live view of the bus. Run it as `agent-bus tui`.
//
// It reads `agent-bus snapshot`, refreshes when the ledger changes, and runs
// the CLI (as you, @lead) for every action. It never writes the bus itself.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

var version = "dev"

const (
	paneAgents = iota
	paneWork   // unused; kept so cursor indexes stay stable
)

type mode int

const (
	modeNormal mode = iota
	modePanel
	modeReply
	modeConfirm
	modeHelp
	modeChat
	modeOpen
	modeSearch
	modeOffboard
)

type model struct {
	w, h     int
	snap     *Snapshot
	err      error
	loading  bool
	stamp    string
	lastLoad time.Time
	cursor   [2]int
	mode     mode
	status   string
	statusAt time.Time
	input    textinput.Model
	seen     map[string]time.Time

	// The side panel: what the selected agent needs from you.
	panel    tile
	panelSel int
	bodies   map[string]string
	target   need

	chatSeat    Seat
	chatPeer    string
	chatMsgs    []chatMsg
	chatStamp   string
	chatView    viewport.Model
	chatSending bool
	chatNote    string
	chatSel     int
	chatFollow  bool // keep the newest entry selected as new ones arrive

	titles     map[string]string // session titles, when an agent set no focus
	titlesAt   time.Time
	services   []service
	servicesAt time.Time
	scanning   bool
	openItems  []openItem
	openSel    int
	query      string // "/" search over the grid
	groupBy    groupBy
}

type snapMsg struct {
	s   *Snapshot
	err error
}
type tickMsg time.Time
type actionMsg struct {
	what string
	out  string
	err  error
}
type showMsg struct {
	id, out string
	err     error
}

func loadCmd() tea.Cmd {
	return func() tea.Msg { s, err := loadSnapshot(); return snapMsg{s, err} }
}

func tick() tea.Cmd {
	return tea.Tick(time.Second, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func actionCmd(what string, args ...string) tea.Cmd {
	return func() tea.Msg { out, err := run(args...); return actionMsg{what, out, err} }
}

func showCmd(id string) tea.Cmd {
	return func() tea.Msg { out, err := run("show", id); return showMsg{id, out, err} }
}

func newModel() model {
	ti := textinput.New()
	ti.CharLimit = 4000
	ti.Prompt = ""
	return model{loading: true, input: ti, seen: map[string]time.Time{}, bodies: map[string]string{}, titles: map[string]string{}}
}

func (m model) Init() tea.Cmd { return tea.Batch(loadCmd(), tick(), scanServicesCmd()) }

func (m model) needsCount() int {
	n := 0
	for _, v := range m.needs() {
		n += len(v)
	}
	return n
}

// ---- layout

const panelMin = 44

// panelW is the side panel's width when it is open, 0 otherwise.
func (m model) panelW() int {
	if m.mode != modePanel && m.mode != modeReply && m.mode != modeConfirm && m.mode != modeOpen && m.mode != modeOffboard {
		return 0
	}
	w := m.w * 2 / 5
	if w < panelMin {
		w = panelMin
	}
	if w > m.w-tileW-6 {
		w = m.w - tileW - 6
	}
	return w
}

// gridSize is the grid's inner width and height, inside its box.
func (m model) gridSize() (int, int) {
	return m.w - m.panelW() - 4, m.h - 2 /* header+footer */ - 2 /* box */ - 1 /* selected line */
}

// ---- update

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		if m.mode == modeChat {
			m.renderChat()
		}
		return m, nil

	case tea.MouseMsg:
		return m.mouse(msg)

	case titlesMsg:
		m.titles = msg
		return m, nil

	case servicesMsg:
		m.scanning = false
		m.servicesAt = time.Now()
		if msg.err == nil {
			m.services = msg.list
		}
		return m, nil

	case chatLoaded:
		if m.mode == modeChat && msg.addr == m.chatSeat.Addr {
			if msg.err != nil {
				m.setStatus("✗ could not read the conversation: " + msg.err.Error())
			} else {
				var keep string
				if !m.chatFollow && m.chatSel >= 0 && m.chatSel < len(m.chatMsgs) {
					keep = m.chatMsgs[m.chatSel].ID + m.chatMsgs[m.chatSel].Kind
				}
				m.chatMsgs = msg.msgs
				m.chatSel = len(m.chatMsgs) - 1
				if keep != "" {
					for i, c := range m.chatMsgs {
						if c.ID+c.Kind == keep {
							m.chatSel = i
						}
					}
				}
				m.renderChat()
			}
		}
		return m, nil

	case offboardSent:
		return m.offboardDone(msg), loadCmd()

	case chatSent:
		m.chatSending = false
		m.chatNote = ""
		if msg.err != nil {
			m.setStatus("✗ not sent: " + firstLine(msg.out))
		}
		// What the CLI says about delivery: woken, queued, or not running.
		for _, l := range strings.Split(msg.out, "\n") {
			if strings.HasPrefix(l, "delivery") {
				if i := strings.Index(l, " — "); i >= 0 {
					l = l[i+len(" — "):]
				} else if i := strings.Index(l, ": "); i >= 0 {
					l = l[i+2:]
				}
				m.chatNote = clean(l)
			}
		}
		if m.mode == modeChat {
			return m, loadChat(m.snap.Bus, m.chatSeat.Addr)
		}
		return m, nil

	case tickMsg:
		var cmd tea.Cmd
		if !m.loading && m.snap != nil {
			if st := ledgerStamp(m.snap.Bus); st != m.stamp || time.Since(m.lastLoad) > 15*time.Second {
				m.loading = true
				cmd = loadCmd()
			}
		}
		if m.mode == modeChat && m.snap != nil && !m.chatSending {
			if st := ledgerStamp(m.snap.Bus); st != m.chatStamp {
				m.chatStamp = st
				cmd = tea.Batch(cmd, loadChat(m.snap.Bus, m.chatSeat.Addr))
			}
		}
		if !m.scanning && time.Since(m.servicesAt) > 10*time.Second {
			m.scanning = true
			cmd = tea.Batch(cmd, scanServicesCmd())
		}
		if m.status != "" && time.Since(m.statusAt) > 6*time.Second {
			m.status = ""
		}
		return m, tea.Batch(cmd, tick())

	case snapMsg:
		m.loading = false
		m.lastLoad = time.Now()
		if msg.err != nil {
			m.err = msg.err
			return m, nil
		}
		m.err = nil
		first := m.snap == nil
		m.snap = msg.s
		m.stamp = ledgerStamp(msg.s.Bus)
		for _, e := range msg.s.Recent {
			if _, ok := m.seen[e.ID+e.Kind]; !ok {
				if first {
					m.seen[e.ID+e.Kind] = time.Time{}
				} else {
					m.seen[e.ID+e.Kind] = time.Now()
				}
			}
		}
		m.clamp()
		cmds := []tea.Cmd{m.loadPanelBody()}
		if time.Since(m.titlesAt) > 30*time.Second {
			m.titlesAt = time.Now()
			cmds = append(cmds, loadTitlesCmd(msg.s.Seats))
		}
		return m, tea.Batch(cmds...)

	case actionMsg:
		if msg.err != nil {
			m.setStatus("✗ " + msg.what + ": " + firstLine(msg.out))
		} else {
			m.setStatus("✓ " + msg.what)
		}
		m.loading = true
		return m, loadCmd()

	case showMsg:
		if msg.err == nil {
			_, body, ok := strings.Cut(msg.out, "\n---\n")
			if !ok {
				body = msg.out
			}
			m.bodies[msg.id] = strings.TrimSpace(body)
		}
		return m, nil

	case tea.KeyMsg:
		return m.key(msg)
	}
	return m, nil
}

func (m *model) setStatus(s string) { m.status, m.statusAt = s, time.Now() }

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return clean(s)
}

func (m *model) clamp() {
	tiles, _ := m.tiles()
	if m.cursor[paneAgents] >= len(tiles) {
		m.cursor[paneAgents] = len(tiles) - 1
	}
	if m.cursor[paneAgents] < 0 {
		m.cursor[paneAgents] = 0
	}
	if n := len(m.panelNeeds()); m.panelSel >= n {
		m.panelSel = max(0, n-1)
	}
}

// panelNeeds is what the agent in the panel is waiting on you for.
func (m model) panelNeeds() []need { return m.needs()[m.panel.seat.Addr] }

func (m model) selectedNeed() (need, bool) {
	ns := m.panelNeeds()
	if m.panelSel < 0 || m.panelSel >= len(ns) {
		return need{}, false
	}
	return ns[m.panelSel], true
}

// loadPanelBody fetches the selected item's full text once.
func (m model) loadPanelBody() tea.Cmd {
	if m.mode == modeNormal || m.mode == modeChat || m.mode == modeHelp {
		return nil
	}
	n, ok := m.selectedNeed()
	if !ok {
		return nil
	}
	if _, have := m.bodies[n.ID]; have {
		return nil
	}
	m.bodies[n.ID] = "" // in flight
	return showCmd(n.ID)
}

func (m model) openPanel() (tea.Model, tea.Cmd) {
	t, ok := m.selectedTile()
	if !ok {
		return m, nil
	}
	m.panel, m.panelSel, m.mode = t, 0, modePanel
	return m, m.loadPanelBody()
}

func (m model) mouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
	if m.snap == nil || m.mode == modeChat || m.mode == modeHelp {
		return m, nil
	}
	if msg.Action != tea.MouseActionPress {
		return m, nil
	}
	switch msg.Button {
	case tea.MouseButtonWheelUp:
		m.moveGrid(0, -1, m.gridW())
		return m, nil
	case tea.MouseButtonWheelDown:
		m.moveGrid(0, 1, m.gridW())
		return m, nil
	case tea.MouseButtonLeft:
	default:
		return m, nil
	}
	gw, gh := m.gridSize()
	// Grid content starts below the header (1) and box border (1), right of
	// the border and padding (2).
	if i := m.tileAt(gw, gh, msg.X-2, msg.Y-2); i >= 0 {
		m.cursor[paneAgents] = i
		if m.mode == modeReply || m.mode == modeConfirm || m.mode == modeOffboard {
			m.input.Blur()
		}
		return m.openPanel()
	}
	return m, nil
}

func (m model) gridW() int { w, _ := m.gridSize(); return w }

func (m model) key(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch m.mode {
	case modeSearch:
		return m.searchKey(k)
	case modeOpen:
		return m.openKey(k)
	case modeChat:
		return m.chatKey(k)
	case modeOffboard:
		return m.offboardKey(k)
	case modeHelp:
		m.mode = modeNormal
		return m, nil
	case modeConfirm:
		m.mode = modePanel
		switch k.String() {
		case "y", "d":
			return m, actionCmd("closed "+short(m.target.ID)+" (done)", "resolve", m.target.ID, "--reason", "done")
		case "c":
			return m, actionCmd("closed "+short(m.target.ID)+" (canceled)", "resolve", m.target.ID, "--reason", "canceled")
		case "n":
			return m, actionCmd("closed "+short(m.target.ID)+" (denied)", "resolve", m.target.ID, "--reason", "denied")
		}
		m.setStatus("not closed")
		return m, nil
	case modeReply:
		switch k.String() {
		case "esc":
			m.mode = modePanel
			m.input.Blur()
			return m, nil
		case "enter":
			v := strings.TrimSpace(m.input.Value())
			m.mode = modePanel
			m.input.Blur()
			if v == "" {
				m.setStatus("empty reply, not sent")
				return m, nil
			}
			return m, actionCmd("replied to "+short(m.target.ID), "reply", m.target.ID, "-m", v)
		}
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(k)
		return m, cmd
	case modePanel:
		switch k.String() {
		case "esc", "q":
			m.mode = modeNormal
			return m, nil
		case "up", "k":
			if m.panelSel > 0 {
				m.panelSel--
			}
			return m, m.loadPanelBody()
		case "down", "j":
			if m.panelSel < len(m.panelNeeds())-1 {
				m.panelSel++
			}
			return m, m.loadPanelBody()
		case "r":
			if n, ok := m.selectedNeed(); ok {
				m.target, m.mode = n, modeReply
				m.input.Placeholder = "your answer · enter sends and closes it · esc cancels"
				m.input.SetValue("")
				m.input.Width = m.panelW() - 6
				m.input.Focus()
				return m, textinput.Blink
			}
			return m, nil
		case "x":
			if n, ok := m.selectedNeed(); ok {
				m.target, m.mode = n, modeConfirm
			}
			return m, nil
		case "c", "enter":
			return m, m.openChat(m.panel.seat, m.panel.peer)
		case "o":
			return m.startOpen(m.panel)
		case "O":
			return m.startOffboard()
		case "left", "right", "h", "l":
			// Fall through to the grid: move and follow with the panel.
		default:
			return m, nil
		}
	}

	switch k.String() {
	case "q", "ctrl+c":
		return m, tea.Quit
	case "/":
		return m.startSearch()
	case "O":
		return m.startOffboard()
	case "a":
		return m, m.openActivity()
	case "g":
		m.groupBy = (m.groupBy + 1) % groupModes
		m.cursor[paneAgents] = 0
		m.setStatus("grouped by " + m.groupBy.String())
	case "esc":
		if m.query != "" {
			m.query = ""
			m.cursor[paneAgents] = 0
		}
	case "?":
		m.mode = modeHelp
	case "left", "h":
		m.moveGrid(-1, 0, m.gridW())
	case "right", "l":
		m.moveGrid(1, 0, m.gridW())
	case "up", "k":
		m.moveGrid(0, -1, m.gridW())
	case "down", "j":
		m.moveGrid(0, 1, m.gridW())
	case "ctrl+r":
		m.loading = true
		return m, loadCmd()
	case "c":
		if t, ok := m.selectedTile(); ok {
			return m, m.openChat(t.seat, t.peer)
		}
	case "enter", " ":
		return m.openPanel()
	case "o":
		if t, ok := m.selectedTile(); ok {
			mm, _ := m.openPanel()
			return mm.(model).startOpen(t)
		}
	}
	if m.mode == modePanel {
		return m.openPanel() // the panel follows the selection
	}
	return m, nil
}

func matchCount(n int) string {
	if n == 1 {
		return "1 match"
	}
	return fmt.Sprintf("%d matches", n)
}

func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return fmt.Sprintf("%d %ss", n, word)
}

func short(id string) string {
	if i := strings.LastIndexByte(id, '-'); i >= 0 && i+1 < len(id) {
		return id[i+1:]
	}
	return id
}

// ---- view

var (
	cAccent = lipgloss.AdaptiveColor{Light: "#5B4BDB", Dark: "#A99BFF"}
	cDim    = lipgloss.AdaptiveColor{Light: "#8A8A8A", Dark: "#6C6C6C"}
	cText   = lipgloss.AdaptiveColor{Light: "#1F1F1F", Dark: "#E4E4E4"}
	cWarn   = lipgloss.AdaptiveColor{Light: "#B25E00", Dark: "#F2A65A"}
	cBad    = lipgloss.AdaptiveColor{Light: "#C22F2F", Dark: "#FF7A7A"}
	cGood   = lipgloss.AdaptiveColor{Light: "#1E8A4C", Dark: "#5CD68D"}
	cSel    = lipgloss.AdaptiveColor{Light: "#ECE9FF", Dark: "#2E2A4A"}

	sDim    = lipgloss.NewStyle().Foreground(cDim)
	sText   = lipgloss.NewStyle().Foreground(cText)
	sAccent = lipgloss.NewStyle().Foreground(cAccent).Bold(true)
	sHeader = lipgloss.NewStyle().Foreground(cDim).Bold(true)
	sSel    = lipgloss.NewStyle().Background(cSel).Foreground(cText).Bold(true)
)

var toolColor = map[string]string{
	"claude": "#D97757", "codex": "#10A37F", "opencode": "#F2C94C",
	"grok": "#9AA0A6", "shell": "#8A8A8A", "lead": "#A99BFF",
}

func colorFor(s Seat) lipgloss.Color {
	if s.Avatar.Color != "" {
		return lipgloss.Color(s.Avatar.Color)
	}
	if c, ok := toolColor[s.Tool]; ok {
		return lipgloss.Color(c)
	}
	return lipgloss.Color("#9AA0A6")
}

func kindStyle(k string) lipgloss.Style {
	switch k {
	case "needs-you", "question", "blocked":
		return lipgloss.NewStyle().Foreground(cBad).Bold(true)
	case "wake-failed", "needs-review", "orphaned", "unfiled":
		return lipgloss.NewStyle().Foreground(cWarn)
	case "handoff":
		return lipgloss.NewStyle().Foreground(cAccent)
	case "merged", "done":
		return lipgloss.NewStyle().Foreground(cGood)
	}
	return sDim
}

func fit(s string, w int) string {
	if w <= 0 {
		return ""
	}
	s = ansi.Truncate(s, w, "…")
	if pad := w - ansi.StringWidth(s); pad > 0 {
		s += strings.Repeat(" ", pad)
	}
	return s
}

func (m model) View() string {
	if m.w == 0 {
		return ""
	}
	if m.snap == nil {
		msg := "reading the bus …"
		if m.err != nil {
			msg = "could not read the bus: " + m.err.Error() + "\n\nIs agent-bus on your PATH? (" + cli() + ")"
		}
		return lipgloss.Place(m.w, m.h, lipgloss.Center, lipgloss.Center, msg)
	}
	switch m.mode {
	case modeHelp:
		return m.helpView()
	case modeChat:
		return m.chatScreen()
	}

	gw, gh := m.gridSize()
	pw := m.panelW()
	agents := m.gridBody(gw, gh) + "\n" + m.selectedLine(gw)
	body := m.box("AGENTS", agents, m.w-pw, gh+3, m.mode == modeNormal)
	if pw > 0 {
		body = lipgloss.JoinHorizontal(lipgloss.Top, body, m.panelView(pw, gh+3))
	}
	parts := []string{m.headerView(), body}
	parts = append(parts, m.footerView())
	return lipgloss.JoinVertical(lipgloss.Left, parts...)
}

func (m model) box(title, body string, w, h int, focus bool) string {
	bc := cDim
	if focus {
		bc = cAccent
	}
	st := lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(bc).
		Width(w-2).Height(h-2).MaxHeight(h).Padding(0, 1)
	out := st.Render(body)
	// Title into the top border.
	t := " " + title + " "
	ts := sHeader
	if focus {
		ts = sAccent
	}
	lines := strings.SplitN(out, "\n", 2)
	if len(lines) == 2 && w > len(t)+4 {
		top := lipgloss.NewStyle().Foreground(bc).Render("╭─") + ts.Render(t) +
			lipgloss.NewStyle().Foreground(bc).Render(strings.Repeat("─", max(0, w-ansi.StringWidth(t)-3))+"╮")
		out = top + "\n" + lines[1]
	}
	return out
}

func (m model) headerView() string {
	host := localHost()
	tiles, _ := m.tiles()
	agents := 0
	for _, t := range tiles {
		if !t.gone {
			agents++
		}
	}
	left := sAccent.Render(" agent-bus") + sDim.Render(" · "+host)
	needs := m.needsCount()
	parts := []string{plural(agents, "agent")}
	if needs > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(cBad).Bold(true).Render(fmt.Sprintf("%d need you", needs)))
	} else {
		parts = append(parts, lipgloss.NewStyle().Foreground(cGood).Render("nothing needs you"))
	}
	if len(m.snap.Peers) > 0 {
		var names []string
		for _, p := range m.snap.Peers {
			names = append(names, p.Name)
		}
		parts = append(parts, "linked: "+strings.Join(names, ", "))
	}
	spin := " "
	if m.loading {
		spin = "↻"
	}
	right := strings.Join(parts, sDim.Render(" · ")) + " " + sDim.Render(spin) + " "
	gap := m.w - ansi.StringWidth(left) - ansi.StringWidth(right)
	if gap < 1 {
		return fit(left, m.w)
	}
	return left + strings.Repeat(" ", gap) + right
}

func (m model) footerView() string {
	if m.status != "" {
		st := sText
		if strings.HasPrefix(m.status, "✗") {
			st = lipgloss.NewStyle().Foreground(cBad)
		} else if strings.HasPrefix(m.status, "✓") {
			st = lipgloss.NewStyle().Foreground(cGood)
		}
		return st.Render(fit(" "+m.status, m.w))
	}
	if m.err != nil {
		return lipgloss.NewStyle().Foreground(cBad).Render(fit(" refresh failed: "+m.err.Error(), m.w))
	}
	keys := []string{"arrows or click: pick an agent", "/: search", "enter: details", "o: open in…", "c: timeline & chat", "a: all activity", "O: offboard", "g: grouped by " + m.groupBy.String(), "?: help", "q: quit"}
	if m.query != "" {
		keys = append([]string{sAccent.Render("/" + m.query), "esc: clear"}, keys[1:]...)
	}
	switch m.mode {
	case modeSearch:
		tiles, _ := m.tiles()
		return " " + sAccent.Render("/") + m.input.View() + sDim.Render(fmt.Sprintf("  %s · arrows move · enter opens · esc clears", matchCount(len(tiles))))
	case modeOpen:
		keys = []string{"↑↓ or number: pick", "enter: open", "esc: back"}
	case modePanel:
		keys = []string{"↑↓ item", "r answer", "x close it", "c timeline & chat", "o open in…", "O offboard", "←→ next agent", "esc back"}
	case modeReply:
		keys = []string{"enter sends and closes it", "esc cancels"}
	case modeOffboard:
		keys = []string{"y asks it to hand on or close its work and run agent-bus offboard", "any other key cancels"}
	case modeConfirm:
		keys = []string{"y done", "c canceled", "n denied", "any other key keeps it"}
	}
	return sDim.Render(fit(" "+strings.Join(keys, " · "), m.w))
}

func (m model) helpView() string {
	lines := []string{
		sAccent.Render("agent-bus tui"),
		"",
		"A live view of the bus. It refreshes whenever the ledger changes.",
		"Actions run agent-bus as you (@lead).",
		"",
		"  arrows / click   pick an agent",
		"  enter            open what it needs from you",
		"  /                search: name, focus, ticket, branch, port (fuzzy)",
		"  c                its timeline: everything it sent, got, closed or decided;",
		"                   ↑↓ moves through it, and you can message it from there",
		"  o                open its folder in Finder, Zed, Cursor… or its ports in a browser",
		"  a                all activity: every message, close and decision on the bus",
		"  g                group by lane, tool, repo, Mac, or nothing",
		"  O                offboard it: ask it to hand on or close its work",
		"                   and run agent-bus offboard",
		"",
		"  in the panel:  ↑↓ item · r answer (and close) · x close · c chat",
		"",
		"  A red badge counts what an agent is waiting on you for.",
		"  Dim bots have been idle 30+ minutes; \"not running\" ones have exited",
		"  but still have something waiting on you.",
		"",
		"  ctrl+r refresh · q quit",
		"",
		sDim.Render("any key to go back"),
	}
	return lipgloss.Place(m.w, m.h, lipgloss.Center, lipgloss.Center,
		lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cAccent).Padding(1, 3).Render(strings.Join(lines, "\n")))
}

// renderShow turns `agent-bus show` output (a JSON header line, ---, the
// body, then any thread) into something readable.
func renderShow(out string, w int) string {
	head, rest, ok := strings.Cut(out, "\n---\n")
	var h map[string]any
	if !ok || !strings.HasPrefix(strings.TrimSpace(head), "{") || json.Unmarshal([]byte(head), &h) != nil {
		return wrap(clean2(out), w)
	}
	str := func(k string) string { v, _ := h[k].(string); return clean(v) }
	var lines []string
	add := func(label, v string) {
		if v != "" {
			lines = append(lines, sDim.Render(fmt.Sprintf("%-8s", label))+" "+v)
		}
	}
	state := str("state")
	if c := str("close"); c != "" {
		state += sDim.Render("  (closes its parent: " + c + ")")
	}
	add("from", lipgloss.NewStyle().Bold(true).Render(str("from"))+sDim.Render("  →  ")+lipgloss.NewStyle().Bold(true).Render(str("to")))
	add("state", kindStyle(str("state")).Render(str("state"))+strings.TrimPrefix(state, str("state")))
	if e, ok := h["epoch"].(float64); ok {
		add("sent", time.Unix(int64(e), 0).Format("Mon Jan 2 15:04")+sDim.Render("  ("+ago(0, int64(e))+" ago)"))
	}
	where := str("repo")
	if b := str("branch"); b != "" {
		where += " · " + b
	}
	add("where", where)
	add("re", str("re"))
	if t, ok := h["touched"].([]any); ok && len(t) > 0 {
		var fs []string
		for _, f := range t {
			if s, ok := f.(string); ok {
				fs = append(fs, clean(s))
			}
		}
		add("touched", strings.Join(fs, ", "))
	}
	add("id", sDim.Render(str("id")))
	return strings.Join(lines, "\n") + "\n\n" + sDim.Render(strings.Repeat("─", min(w, 60))) + "\n\n" + wrap(clean2(strings.TrimSpace(rest)), w)
}

// clean2 keeps newlines (for show output) but strips other control characters.
func clean2(s string) string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		out = append(out, clean(l))
	}
	return strings.Join(out, "\n")
}

func wrap(s string, w int) string {
	if w < 20 {
		return s
	}
	return lipgloss.NewStyle().Width(w).Render(s)
}

func main() {
	for _, a := range os.Args[1:] {
		switch a {
		case "--version", "version":
			fmt.Println("agent-bus-tui", version)
			return
		case "-h", "--help", "help":
			fmt.Println("usage: agent-bus tui\n\nA live view of your agents, here and on linked Macs: what each needs from you, and a chat with any of them.\nKeys: ? in the app.")
			return
		}
	}
	p := tea.NewProgram(newModel(), tea.WithAltScreen(), tea.WithMouseCellMotion())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "agent-bus tui:", err)
		os.Exit(1)
	}
}
