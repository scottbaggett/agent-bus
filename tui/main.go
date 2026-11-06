// agent-bus-tui: a live view of the bus. Run it as `agent-bus tui`.
//
// It reads `agent-bus snapshot`, refreshes when the ledger changes, and runs
// the CLI (as you, @lead) for every action. It never writes the bus itself.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
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
	paneWork
)

const (
	tabNeeds = iota
	tabOpen
)

type mode int

const (
	modeNormal mode = iota
	modeDetail
	modeReply
	modeConfirm
	modeFilter
	modeHelp
	modeChat
)

// row is one line in the work list, from either attention or open work.
type row struct {
	id, kind, who, from, text, fix, lane string
	epoch                                int64
	stale                                bool
}

type model struct {
	w, h      int
	snap      *Snapshot
	err       error
	loading   bool
	stamp     string
	lastLoad  time.Time
	pane      int
	tab       int
	cursor    [2]int
	offset    [2]int
	showStale bool
	filter    string
	mode      mode
	status    string
	statusAt  time.Time
	input     textinput.Model
	view      viewport.Model
	target    row
	seen      map[string]time.Time

	chatSeat    Seat
	chatPeer    string
	chatMsgs    []chatMsg
	chatStamp   string
	chatView    viewport.Model
	chatSending bool
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
	return model{loading: true, input: ti, seen: map[string]time.Time{}, pane: paneAgents}
}

func (m model) Init() tea.Cmd { return tea.Batch(loadCmd(), tick()) }

// ---- data shaping

func (m model) workRows() []row {
	if m.snap == nil {
		return nil
	}
	var rows []row
	if m.tab == tabNeeds {
		for _, a := range m.snap.Attention {
			if !m.showStale && (a.Kind == "orphaned" || a.Kind == "merged") {
				continue
			}
			rows = append(rows, row{id: a.ID, kind: a.Kind, who: a.From, from: a.From, text: a.Text, fix: a.Fix, lane: a.Lane, epoch: a.Epoch})
		}
		// What needs you first, then newest.
		rank := func(k string) int {
			switch k {
			case "needs-you":
				return 0
			case "wake-failed":
				return 1
			}
			return 2
		}
		sort.SliceStable(rows, func(i, j int) bool {
			if rank(rows[i].kind) != rank(rows[j].kind) {
				return rank(rows[i].kind) < rank(rows[j].kind)
			}
			return rows[i].epoch > rows[j].epoch
		})
	} else {
		for _, it := range m.snap.Open {
			stale := it.Gone || it.Stale
			if stale && !m.showStale {
				continue
			}
			rows = append(rows, row{id: it.ID, kind: it.State, who: it.From + " → " + it.To, from: it.From, text: it.Subject, lane: it.Lane, epoch: it.Epoch, stale: stale})
		}
		sort.SliceStable(rows, func(i, j int) bool { return rows[i].epoch > rows[j].epoch })
	}
	if f := strings.ToLower(m.filter); f != "" {
		var keep []row
		for _, r := range rows {
			if strings.Contains(strings.ToLower(r.kind+" "+r.who+" "+r.text+" "+r.lane+" "+r.id), f) {
				keep = append(keep, r)
			}
		}
		rows = keep
	}
	return rows
}

func (m model) needsCount() int {
	n := 0
	if m.snap != nil {
		for _, a := range m.snap.Attention {
			if a.Kind == "needs-you" {
				n++
			}
		}
	}
	return n
}

func (m model) liveOpen() int {
	n := 0
	if m.snap != nil {
		for _, it := range m.snap.Open {
			if !it.Gone && !it.Stale {
				n++
			}
		}
	}
	return n
}

// ---- update

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		m.view.Width, m.view.Height = m.w-4, m.h-4
		if m.mode == modeChat {
			m.renderChat()
		}
		return m, nil

	case chatLoaded:
		if m.mode == modeChat && msg.addr == m.chatSeat.Addr {
			if msg.err != nil {
				m.setStatus("✗ could not read the conversation: " + msg.err.Error())
			} else {
				m.chatMsgs = msg.msgs
				m.renderChat()
			}
		}
		return m, nil

	case chatSent:
		m.chatSending = false
		if msg.err != nil {
			m.setStatus("✗ not sent: " + firstLine(msg.out))
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
		return m, nil

	case actionMsg:
		if msg.err != nil {
			m.setStatus("✗ " + msg.what + ": " + firstLine(msg.out))
		} else {
			m.setStatus("✓ " + msg.what)
		}
		m.loading = true
		return m, loadCmd()

	case showMsg:
		if msg.err != nil {
			m.setStatus("✗ show: " + firstLine(msg.out))
			m.mode = modeNormal
			return m, nil
		}
		m.view = viewport.New(m.w-4, m.h-4)
		m.view.SetContent(renderShow(msg.out, m.w-6))
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
	n := [2]int{len(tiles), len(m.workRows())}
	for p := 0; p < 2; p++ {
		if m.cursor[p] >= n[p] {
			m.cursor[p] = n[p] - 1
		}
		if m.cursor[p] < 0 {
			m.cursor[p] = 0
		}
	}
}

func (m model) selected() (row, bool) {
	rows := m.workRows()
	if m.pane != paneWork || len(rows) == 0 {
		return row{}, false
	}
	return rows[m.cursor[paneWork]], true
}

func (m model) key(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch m.mode {
	case modeChat:
		return m.chatKey(k)
	case modeHelp:
		m.mode = modeNormal
		return m, nil
	case modeDetail:
		switch k.String() {
		case "esc", "q", "enter":
			m.mode = modeNormal
			return m, nil
		case "r":
			m.mode = modeNormal
			return m.startReply()
		case "x":
			m.mode = modeConfirm
			return m, nil
		}
		var cmd tea.Cmd
		m.view, cmd = m.view.Update(k)
		return m, cmd
	case modeConfirm:
		m.mode = modeNormal
		switch k.String() {
		case "y", "d":
			return m, actionCmd("closed "+short(m.target.id)+" (done)", "resolve", m.target.id, "--reason", "done")
		case "c":
			return m, actionCmd("closed "+short(m.target.id)+" (canceled)", "resolve", m.target.id, "--reason", "canceled")
		case "n":
			return m, actionCmd("closed "+short(m.target.id)+" (denied)", "resolve", m.target.id, "--reason", "denied")
		}
		m.setStatus("not closed")
		return m, nil
	case modeReply, modeFilter:
		switch k.String() {
		case "esc":
			if m.mode == modeFilter {
				m.filter = ""
			}
			m.mode = modeNormal
			m.input.Blur()
			return m, nil
		case "enter":
			v := strings.TrimSpace(m.input.Value())
			wasReply := m.mode == modeReply
			m.mode = modeNormal
			m.input.Blur()
			if wasReply {
				if v == "" {
					m.setStatus("empty reply, not sent")
					return m, nil
				}
				return m, actionCmd("replied to "+short(m.target.id), "reply", m.target.id, "-m", v)
			}
			m.filter = v
			m.cursor[paneWork], m.offset[paneWork] = 0, 0
			return m, nil
		}
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(k)
		if m.mode == modeFilter {
			m.filter = m.input.Value()
			m.cursor[paneWork], m.offset[paneWork] = 0, 0
		}
		return m, cmd
	}

	switch k.String() {
	case "q", "ctrl+c":
		return m, tea.Quit
	case "?":
		m.mode = modeHelp
	case "tab", "shift+tab":
		m.pane = 1 - m.pane
	case "left", "h":
		if m.pane == paneAgents {
			m.moveGrid(-1, 0, m.w-4)
		}
	case "right", "l":
		if m.pane == paneAgents {
			m.moveGrid(1, 0, m.w-4)
		}
	case "1":
		m.tab, m.pane, m.cursor[paneWork], m.offset[paneWork] = tabNeeds, paneWork, 0, 0
	case "2":
		m.tab, m.pane, m.cursor[paneWork], m.offset[paneWork] = tabOpen, paneWork, 0, 0
	case "s":
		m.showStale = !m.showStale
		m.cursor[paneWork], m.offset[paneWork] = 0, 0
		if m.showStale {
			m.setStatus("showing stale and orphaned items")
		} else {
			m.setStatus("hiding stale and orphaned items")
		}
	case "/":
		m.mode = modeFilter
		m.input.Placeholder = "filter"
		m.input.SetValue(m.filter)
		m.input.CursorEnd()
		m.input.Focus()
		m.pane = paneWork
	case "up", "k":
		m.move(-1)
	case "down", "j":
		m.move(1)
	case "pgup":
		m.move(-10)
	case "pgdown":
		m.move(10)
	case "home", "g":
		m.cursor[m.pane] = 0
	case "end", "G":
		m.cursor[m.pane] = 1 << 30
		m.clamp()
	case "ctrl+r":
		m.loading = true
		return m, loadCmd()
	case "c":
		if r, ok := m.selected(); ok && r.from != "" {
			if s, peer, ok := m.findSeat(r.from); ok {
				return m, m.openChat(s, peer)
			}
			return m, m.openChat(Seat{Addr: r.from, Tool: strings.SplitN(r.from, "/", 2)[0]}, "")
		}
	case "enter":
		if m.pane == paneAgents {
			if t, ok := m.selectedTile(); ok {
				return m, m.openChat(t.seat, t.peer)
			}
			return m, nil
		}
		if r, ok := m.selected(); ok && r.id != "" {
			m.target = r
			m.mode = modeDetail
			m.view = viewport.New(m.w-4, m.h-4)
			m.view.SetContent("loading " + r.id + " …")
			return m, showCmd(r.id)
		}
	case "r":
		return m.startReply()
	case "x":
		if r, ok := m.selected(); ok && r.id != "" {
			m.target = r
			m.mode = modeConfirm
		}
	}
	return m, nil
}

func (m model) startReply() (tea.Model, tea.Cmd) {
	r, ok := m.selected()
	if m.mode == modeNormal && m.target.id != "" && !ok {
		r, ok = m.target, true
	}
	if !ok || r.id == "" {
		return m, nil
	}
	m.target = r
	m.mode = modeReply
	m.input.Placeholder = "reply as you; enter sends and closes it, esc cancels"
	m.input.SetValue("")
	m.input.Focus()
	return m, textinput.Blink
}

func (m *model) move(d int) {
	if m.pane == paneWork {
		m.cursor[paneWork] += d
		m.clamp()
		return
	}
	dy := 1
	if d < 0 {
		dy = -1
	}
	for i := 0; i < d*dy && i < 3; i++ {
		m.moveGrid(0, dy, m.w-4)
	}
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
	case modeDetail:
		return m.detailView()
	case modeHelp:
		return m.helpView()
	case modeChat:
		return m.chatScreen()
	}

	header := m.headerView()
	footer := m.footerView()
	feedH := 7
	if m.h < 30 {
		feedH = 4
	}
	avail := m.h - lipgloss.Height(header) - lipgloss.Height(footer) - feedH
	// The grid takes what it needs, leaving the work list at least 8 lines.
	gridH := m.gridNeeded(m.w-4) + 3
	if maxG := avail - 8; gridH > maxG {
		gridH = maxG
	}
	if gridH < 8 {
		gridH = 8
	}
	workH := avail - gridH
	if workH < 4 {
		workH = 4
	}
	gridInner := gridH - 2
	agents := m.gridBody(m.w-4, gridInner-1) + "\n" + m.selectedLine(m.w-4)
	grid := m.box("AGENTS", agents, m.w, gridH, m.pane == paneAgents)
	work := m.box(m.workTitle(), m.workBody(m.w-4, workH-2), m.w, workH, m.pane == paneWork)
	feed := m.box("LIVE", m.feedBody(m.w-4, feedH-2), m.w, feedH, false)

	return lipgloss.JoinVertical(lipgloss.Left, header, grid, work, feed, footer)
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
	host, _ := os.Hostname()
	host = strings.TrimSuffix(strings.SplitN(host, ".", 2)[0], ".local")
	agents := len(m.snap.Seats)
	for _, p := range m.snap.Peers {
		agents += len(p.Seats)
	}
	left := sAccent.Render(" agent-bus") + sDim.Render(" · "+host)
	needs := m.needsCount()
	parts := []string{plural(agents, "agent")}
	if needs > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(cBad).Bold(true).Render(fmt.Sprintf("%d need you", needs)))
	} else {
		parts = append(parts, lipgloss.NewStyle().Foreground(cGood).Render("nothing needs you"))
	}
	parts = append(parts, fmt.Sprintf("%d open", m.liveOpen()))
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

func (m model) workTitle() string {
	n := len(m.workRows())
	needs, open := "1 needs you", "2 open"
	if m.tab == tabNeeds {
		needs = fmt.Sprintf("[1 NEEDS YOU · %d]", n)
	} else {
		open = fmt.Sprintf("[2 OPEN · %d]", n)
	}
	t := needs + "  " + open
	if m.filter != "" {
		t += "  /" + m.filter
	}
	if m.showStale {
		t += "  +stale"
	}
	return t
}

func scroll(off, cur, h, n int) int {
	if h <= 0 {
		return 0
	}
	if cur < off {
		off = cur
	}
	if cur >= off+h {
		off = cur - h + 1
	}
	if off > n-h {
		off = n - h
	}
	if off < 0 {
		off = 0
	}
	return off
}

func (m model) workBody(w, h int) string {
	rows := m.workRows()
	if len(rows) == 0 {
		msg := "nothing here"
		if m.tab == tabNeeds {
			msg = "nothing needs you"
		}
		if m.filter != "" {
			msg = "no match for /" + m.filter
		}
		hint := ""
		if !m.showStale {
			hint = "\n" + sDim.Render("s shows stale and orphaned items")
		}
		return sDim.Render(msg) + hint
	}
	listH := h
	if m.mode == modeReply || m.mode == modeFilter || m.mode == modeConfirm {
		listH = h - 2
	}
	cur := m.cursor[paneWork]
	off := scroll(m.offset[paneWork], cur, listH, len(rows))
	kindW, whoW, ageW := 12, 28, 4
	if w < 80 {
		whoW = 18
	}
	var b []string
	for i := off; i < len(rows) && len(b) < listH; i++ {
		r := rows[i]
		age := fit(ago(m.snap.Now, r.epoch), ageW)
		kind := kindStyle(r.kind).Render(fit(r.kind, kindW))
		who := fit(clean(r.who), whoW)
		text := clean(r.text)
		textW := w - ageW - kindW - whoW - 3
		line := sDim.Render(age) + " " + kind + " " + sDim.Render(who) + " " + fit(text, textW)
		if r.stale {
			line = sDim.Render(ansi.Strip(line))
		}
		if m.pane == paneWork && i == cur {
			line = sSel.Render(fit(ansi.Strip(line), w))
		}
		b = append(b, line)
	}
	for len(b) < listH {
		b = append(b, "")
	}
	switch m.mode {
	case modeReply:
		b = append(b, sDim.Render(fit("reply to "+short(m.target.id)+" · "+clean(m.target.text), w)), m.input.View())
	case modeFilter:
		b = append(b, "", "/"+m.input.View())
	case modeConfirm:
		b = append(b, "", lipgloss.NewStyle().Foreground(cWarn).Render(fit(
			"close "+short(m.target.id)+"?  y done · c canceled · n denied · any other key keeps it", w)))
	}
	return strings.Join(b, "\n")
}

func (m model) feedBody(w, h int) string {
	if len(m.snap.Recent) == 0 {
		return sDim.Render("quiet")
	}
	var b []string
	for _, e := range m.snap.Recent {
		if len(b) >= h {
			break
		}
		t := time.Unix(e.Epoch, 0).Format("15:04")
		var what string
		switch e.Kind {
		case "msg":
			arrow := clean(e.From) + " → " + clean(e.To)
			st := e.State
			if e.Close != "" {
				st = "closed " + e.Close
			}
			what = arrow + "  " + kindStyle(e.State).Render(st) + "  " + clean(e.Subject)
		case "resolve":
			what = clean(e.From) + "  " + lipgloss.NewStyle().Foreground(cGood).Render("closed "+e.Reason) + "  " + clean(e.Subject)
		case "delivery":
			what = "→ " + clean(e.To) + "  " + sDim.Render(e.Status+" via "+e.Transport) + "  " + clean(e.Subject)
		case "decision":
			what = clean(e.From) + "  " + sAccent.Render("decided") + "  " + clean(e.Subject)
		default:
			what = clean(e.From) + "  " + e.Kind + "  " + clean(e.Subject)
		}
		mark := "  "
		if at := m.seen[e.ID+e.Kind]; !at.IsZero() && time.Since(at) < 20*time.Second {
			mark = sAccent.Render("•") + " "
		}
		line := mark + sDim.Render(t) + "  " + fit(what, w-9)
		b = append(b, line)
	}
	return strings.Join(b, "\n")
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
	keys := []string{"↑↓ move", "tab pane", "1/2 list", "enter show", "c chat", "r reply", "x close", "/ filter", "s stale", "? help", "q quit"}
	if m.pane == paneAgents {
		keys = []string{"←↑↓→ move", "enter chat", "tab work list", "1/2 list", "? help", "q quit"}
	}
	return sDim.Render(fit(" "+strings.Join(keys, " · "), m.w))
}

func (m model) detailView() string {
	title := sAccent.Render(" "+short(m.target.id)) + sDim.Render("  "+fit(clean(m.target.text), m.w-20))
	help := sDim.Render(" ↑↓ scroll · r reply · x close · esc back")
	body := lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cAccent).
		Width(m.w-2).Height(m.h-4).Padding(0, 1).Render(m.view.View())
	return lipgloss.JoinVertical(lipgloss.Left, title, body, help)
}

func (m model) helpView() string {
	lines := []string{
		sAccent.Render("agent-bus tui"),
		"",
		"A live view of the bus. It refreshes whenever the ledger changes.",
		"Actions run agent-bus as you (@lead).",
		"",
		"  arrows / hjkl  move         tab         agents ↔ work list",
		"  1            what needs you 2           open work",
		"  enter        show the item, or chat with the selected agent",
		"  c            chat with whoever sent the item",
		"  r            reply (and close)",
		"  x            close it       /           filter",
		"  s            stale items    ctrl+r      refresh now",
		"  q            quit",
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
			fmt.Println("usage: agent-bus tui\n\nA live view of the bus: agents on this Mac and linked ones, what needs you, open work, and a live feed.\nKeys: ? in the app.")
			return
		}
	}
	p := tea.NewProgram(newModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "agent-bus tui:", err)
		os.Exit(1)
	}
}
