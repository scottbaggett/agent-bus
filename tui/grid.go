package main

import (
	"fmt"
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// The agents pane: a grid of bots, one group per lane, with agents on linked
// Macs in the same lane as yours. An agent waiting on you gets a red border.

const (
	tileInner = 18 // robot (10) centered; text wraps or truncates to this
	tileW     = tileInner + 2
	tileH     = 13 // border + robot(7) + name + focus(2) + ticket·age
	tileGap   = 1
)

type tile struct {
	seat Seat
	peer string // the Mac it's on, "" for this one
	gone bool   // not running, but still waiting on you
}

type laneGroup struct {
	name   string
	tiles  []int
	needs  int
	latest int64
}

// need is one thing an agent is waiting on you for.
type need struct {
	ID, From, State, Subject string
	Epoch                    int64
}

// needs lists, per agent, what it is waiting on you for: questions and work
// sent to you, and the items agent-bus flags as needing you. Newest first.
func (m model) needs() map[string][]need {
	out := map[string][]need{}
	if m.snap == nil {
		return out
	}
	seen := map[string]bool{}
	subj := map[string]Item{}
	for _, it := range m.snap.Open {
		subj[it.ID] = it
	}
	live := map[string]bool{}
	for _, s := range m.snap.Seats {
		live[s.Addr] = true
	}
	for _, a := range m.snap.Attention {
		if a.Kind != "needs-you" || a.From == "" || a.ID == "" || seen[a.ID] {
			continue
		}
		// A stale ask from an agent that has exited can't be acted on: answering
		// reaches no one. It stays in `agent-bus triage`, not on the grid.
		if it, ok := subj[a.ID]; ok && it.Stale && !live[a.From] {
			continue
		}
		seen[a.ID] = true
		n := need{ID: a.ID, From: a.From, State: "question", Subject: a.Text, Epoch: a.Epoch}
		if it, ok := subj[a.ID]; ok {
			n.State, n.Subject = it.State, it.Subject
		} else if i := strings.Index(a.Text, " asks you: "); i >= 0 {
			n.Subject = a.Text[i+len(" asks you: "):]
		}
		out[a.From] = append(out[a.From], n)
	}
	for _, it := range m.snap.Open {
		if it.Stale || seen[it.ID] || !toYou(it.To) || it.From == "" {
			continue
		}
		seen[it.ID] = true
		out[it.From] = append(out[it.From], need{ID: it.ID, From: it.From, State: it.State, Subject: it.Subject, Epoch: it.Epoch})
	}
	for k := range out {
		sort.SliceStable(out[k], func(i, j int) bool { return out[k][i].Epoch > out[k][j].Epoch })
	}
	return out
}

func (m model) needsYou() map[string]int {
	out := map[string]int{}
	for k, v := range m.needs() {
		out[k] = len(v)
	}
	return out
}

// tiles orders every agent by lane: lanes that need you first, then the most
// recently active; agents without a lane last.
func (m model) tiles() ([]tile, []laneGroup) {
	if m.snap == nil {
		return nil, nil
	}
	var all []tile
	for _, s := range m.snap.Seats {
		all = append(all, tile{seat: s})
	}
	for _, p := range m.snap.Peers {
		for _, s := range p.Seats {
			all = append(all, tile{seat: s, peer: p.Name})
		}
	}
	needs := m.needsYou()
	// Agents that have exited but still wait on you keep a tile.
	live := map[string]bool{}
	for _, t := range all {
		live[t.seat.Addr] = true
	}
	var ghosts []string
	for addr := range needs {
		if !live[addr] {
			ghosts = append(ghosts, addr)
		}
	}
	sort.Strings(ghosts)
	for _, addr := range ghosts {
		var ep int64
		for _, n := range m.needs()[addr] {
			ep = max(ep, n.Epoch)
		}
		all = append(all, tile{seat: Seat{Addr: addr, Tool: strings.SplitN(addr, "/", 2)[0], Epoch: ep}, gone: true})
	}
	if q := strings.TrimSpace(m.query); q != "" {
		var keep []tile
		for _, t := range all {
			if m.matches(t, q) {
				keep = append(keep, t)
			}
		}
		all = keep
	}
	byKey := map[string]*laneGroup{}
	var order []string
	for i, t := range all {
		l := m.groupBy.key(t)
		g := byKey[l]
		if g == nil {
			g = &laneGroup{name: l}
			byKey[l] = g
			order = append(order, l)
		}
		g.tiles = append(g.tiles, i)
		g.needs += needs[t.seat.Addr]
		if t.seat.Epoch > g.latest {
			g.latest = t.seat.Epoch
		}
	}
	sort.SliceStable(order, func(i, j int) bool {
		a, b := byKey[order[i]], byKey[order[j]]
		if (a.name == "") != (b.name == "") {
			return b.name == ""
		}
		if (a.needs > 0) != (b.needs > 0) {
			return a.needs > 0
		}
		return a.latest > b.latest
	})
	var tiles []tile
	var groups []laneGroup
	for _, l := range order {
		g := byKey[l]
		// Within a lane: needs you first, then most recent.
		sort.SliceStable(g.tiles, func(i, j int) bool {
			a, b := all[g.tiles[i]], all[g.tiles[j]]
			if (needs[a.seat.Addr] > 0) != (needs[b.seat.Addr] > 0) {
				return needs[a.seat.Addr] > 0
			}
			return a.seat.Epoch > b.seat.Epoch
		})
		ng := laneGroup{name: g.name, needs: g.needs, latest: g.latest}
		for _, i := range g.tiles {
			ng.tiles = append(ng.tiles, len(tiles))
			tiles = append(tiles, all[i])
		}
		groups = append(groups, ng)
	}
	return tiles, groups
}

func gridCols(w int) int {
	c := (w + tileGap) / (tileW + tileGap)
	if c < 1 {
		c = 1
	}
	return c
}

const groupGap = 3

// placed is a tile's position in the laid-out grid.
type placed struct{ x, y int }

// gridLayout flows the lane groups left to right, wrapping like text: each
// group is a header over its tiles. It returns the rendered lines and where
// each tile landed, for scrolling and moving the selection.
func (m model) gridLayout(w int) ([]string, []placed) {
	tiles, groups := m.tiles()
	if len(tiles) == 0 {
		return []string{sDim.Render("no agents running")}, nil
	}
	needs := m.needsYou()
	cur := m.cursor[paneAgents]
	maxCols := gridCols(w)
	pos := make([]placed, len(tiles))

	var lines []string
	var shelf []string // rendered blocks on the current shelf
	shelfX, shelfY, shelfH := 0, 0, 0
	flush := func() {
		if len(shelf) == 0 {
			return
		}
		lines = append(lines, strings.Split(lipgloss.JoinHorizontal(lipgloss.Top, shelf...), "\n")...)
		shelf, shelfX, shelfY, shelfH = nil, 0, len(lines), 0
	}
	for _, g := range groups {
		cols := min(len(g.tiles), maxCols)
		bw := cols*(tileW+tileGap) - tileGap
		rowsN := (len(g.tiles) + cols - 1) / cols
		bh := 1 + rowsN*tileH
		gap := 0
		if len(shelf) > 0 {
			gap = groupGap
		}
		if shelfX+gap+bw > w {
			flush()
			gap = 0
		}
		x0 := shelfX + gap
		name := g.name
		if name == "" {
			name = m.groupBy.emptyLabel()
		}
		head := sHeader.Render(name)
		if g.needs > 0 {
			head = lipgloss.NewStyle().Foreground(cBad).Bold(true).Render(name + " ●")
		}
		if n := len(g.tiles); bw-lipgloss.Width(head) > 4 && n > 1 {
			head += sDim.Render(fmt.Sprintf(" · %d", n))
		}
		var trows []string
		for r := 0; r < rowsN; r++ {
			var cells []string
			for c := 0; c < cols; c++ {
				i := r*cols + c
				if i >= len(g.tiles) {
					break
				}
				ti := g.tiles[i]
				pos[ti] = placed{x: x0 + c*(tileW+tileGap), y: shelfY + 1 + r*tileH}
				if c > 0 {
					cells = append(cells, strings.Repeat(" ", tileGap))
				}
				cells = append(cells, m.renderTile(tiles[ti], ti == cur, needs[tiles[ti].seat.Addr]))
			}
			trows = append(trows, lipgloss.JoinHorizontal(lipgloss.Top, cells...))
		}
		block := lipgloss.JoinVertical(lipgloss.Left, append([]string{fit(head, bw)}, trows...)...)
		block = lipgloss.NewStyle().Width(bw).Render(block)
		if gap > 0 {
			shelf = append(shelf, strings.Repeat(" ", gap))
		}
		shelf = append(shelf, block)
		shelfX = x0 + bw
		if bh > shelfH {
			shelfH = bh
		}
	}
	flush()
	return lines, pos
}

// gridNeeded is how many lines the whole grid wants.
func (m model) gridNeeded(w int) int {
	lines, _ := m.gridLayout(w)
	return len(lines)
}

// moveGrid moves the selection to the nearest tile in a direction.
func (m *model) moveGrid(dx, dy int, w int) {
	_, pos := m.gridLayout(w)
	cur := m.cursor[paneAgents]
	if cur < 0 || cur >= len(pos) {
		m.cursor[paneAgents] = 0
		return
	}
	p := pos[cur]
	best, bestD := -1, 1<<30
	for i, q := range pos {
		if i == cur {
			continue
		}
		var d int
		switch {
		case dx > 0 && q.y == p.y && q.x > p.x:
			d = q.x - p.x
		case dx < 0 && q.y == p.y && q.x < p.x:
			d = p.x - q.x
		case dy > 0 && q.y > p.y:
			d = (q.y-p.y)*1000 + abs(q.x-p.x)
		case dy < 0 && q.y < p.y:
			d = (p.y-q.y)*1000 + abs(q.x-p.x)
		default:
			continue
		}
		if d < bestD {
			best, bestD = i, d
		}
	}
	if best < 0 && dx != 0 {
		// End of a row: wrap to the next or previous tile.
		if n := cur + dx; n >= 0 && n < len(pos) {
			best = n
		}
	}
	if best >= 0 {
		m.cursor[paneAgents] = best
	}
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

func (m model) selectedTile() (tile, bool) {
	tiles, _ := m.tiles()
	c := m.cursor[paneAgents]
	if c < 0 || c >= len(tiles) {
		return tile{}, false
	}
	return tiles[c], true
}

func (m model) findSeat(addr string) (Seat, string, bool) {
	tiles, _ := m.tiles()
	for _, t := range tiles {
		if t.seat.Addr == addr {
			return t.seat, t.peer, true
		}
	}
	return Seat{}, "", false
}

func (m model) renderTile(t tile, selected bool, needs int) string {
	s := t.seat
	idle := t.gone || m.snap.Now-s.Epoch > 30*60
	art := avatarArt(s.Addr, toolOf(s), idle && !selected && needs == 0)
	art = lipgloss.PlaceHorizontal(tileInner, lipgloss.Center, art)

	nameSt := sText.Bold(true)
	if selected {
		nameSt = lipgloss.NewStyle().Foreground(cAccent).Bold(true)
	}
	meta := ago(m.snap.Now, s.Epoch)
	switch {
	case t.gone:
		meta = "not running"
	case t.peer != "":
		meta = t.peer + " · " + meta
	}
	if on := workingOn(s); on != "" && !t.gone {
		meta = on + " · " + meta
	}
	center := func(st string) string { return lipgloss.PlaceHorizontal(tileInner, lipgloss.Center, st) }
	shrink := func(st string) string { return fit(st, min(tileInner, lipgloss.Width(st))) }
	// What it's doing, in up to two lines.
	doing := wrapLines(m.doing(s), tileInner, 2)
	for len(doing) < 2 {
		doing = append(doing, "")
	}
	metaLine := sDim.Render(shrink(meta))
	if svc := m.ownPorts(s); len(svc) > 0 {
		p := ports(svc)
		metaLine = lipgloss.NewStyle().Foreground(cGood).Render(shrink(p)) + sDim.Render(" · "+ago(m.snap.Now, s.Epoch))
		if lipgloss.Width(metaLine) > tileInner {
			metaLine = lipgloss.NewStyle().Foreground(cGood).Render(shrink(p))
		}
	}
	body := art + "\n" +
		center(nameSt.Render(shrink(friendlyName(s.Addr)))) + "\n" +
		center(sText.Render(doing[0])) + "\n" +
		center(sText.Render(doing[1])) + "\n" +
		center(metaLine)

	border := lipgloss.RoundedBorder()
	bc := lipgloss.TerminalColor(cDim)
	switch {
	case needs > 0 && selected:
		border, bc = lipgloss.ThickBorder(), cBad
	case needs > 0:
		bc = cBad
	case selected:
		border, bc = lipgloss.ThickBorder(), cAccent
	}
	out := lipgloss.NewStyle().Border(border).BorderForeground(bc).Width(tileInner).Render(body)
	if needs == 0 {
		return out
	}
	// The badge sits in the top border: ╭───────── 2 ─╮
	badge := lipgloss.NewStyle().Background(cBad).Foreground(lipgloss.Color("#FFFFFF")).Bold(true).Render(fmt.Sprintf(" %d ", needs))
	bs := lipgloss.NewStyle().Foreground(bc)
	fill := tileInner - lipgloss.Width(badge) - 1
	top := bs.Render(border.TopLeft+strings.Repeat(border.Top, fill)) + badge + bs.Render(border.Top+border.TopRight)
	lines := strings.SplitN(out, "\n", 2)
	return top + "\n" + lines[1]
}

// midFit shortens from the middle, keeping the instance id at the end:
// salt-monorepo.0b81 -> salt-mo….0b81.
func midFit(s string, w int) string {
	r := []rune(s)
	if len(r) <= w {
		return s
	}
	tail := 5
	if i := strings.LastIndexByte(s, '.'); i >= 0 && len(s)-i <= 6 {
		tail = len([]rune(s[i:]))
	}
	head := w - tail - 1
	if head < 1 {
		return string(r[:w-1]) + "…"
	}
	return string(r[:head]) + "…" + string(r[len(r)-tail:])
}

// gridOffset is how far the grid is scrolled to keep the selection in view.
func (m model) gridOffset(w, h int) int {
	lines, pos := m.gridLayout(w)
	off := 0
	if cur := m.cursor[paneAgents]; cur >= 0 && cur < len(pos) {
		top, bot := pos[cur].y-1, pos[cur].y+tileH // with its lane header
		if bot > h {
			off = bot - h
		}
		if top < off {
			off = max(0, top)
		}
	}
	if off > len(lines)-h {
		off = max(0, len(lines)-h)
	}
	return off
}

// gridBody renders the grid into h lines, scrolled to keep the selection in view.
func (m model) gridBody(w, h int) string {
	lines, _ := m.gridLayout(w)
	off := m.gridOffset(w, h)
	end := min(len(lines), off+h)
	return strings.Join(lines[off:end], "\n")
}

// tileAt is the tile under a point in grid coordinates (after scrolling).
func (m model) tileAt(w, h, x, y int) int {
	_, pos := m.gridLayout(w)
	y += m.gridOffset(w, h)
	for i, p := range pos {
		if x >= p.x && x < p.x+tileW && y >= p.y && y < p.y+tileH {
			return i
		}
	}
	return -1
}

// selectedLine describes the selected agent in one line.
func (m model) selectedLine(w int) string {
	t, ok := m.selectedTile()
	if !ok {
		return ""
	}
	s := t.seat
	parts := []string{lipgloss.NewStyle().Foreground(cAccent).Bold(true).Render(friendlyName(s.Addr)), sDim.Render(clean(s.Addr))}
	if d := m.doing(s); d != "" {
		parts = append(parts, d)
	}
	if svc := m.servicesFor(s); len(svc) > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(cGood).Render(ports(svc)))
	}
	if t.peer != "" {
		parts = append(parts, "on "+t.peer)
	}
	if s.Repo != "" && s.Repo != "-" {
		parts = append(parts, clean(s.Repo))
	}
	if s.Branch != "" && s.Branch != "-" {
		parts = append(parts, clean(s.Branch))
	}
	if t.gone {
		parts = append(parts, "not running")
	} else {
		parts = append(parts, "seen "+ago(m.snap.Now, s.Epoch)+" ago")
	}
	if n := m.needsYou()[s.Addr]; n > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(cBad).Bold(true).Render(fmt.Sprintf("%d waiting on you", n)))
	}
	return fit(strings.Join(parts, sDim.Render(" · ")), w)
}

// doing is what an agent says it's on: its focus line, else its session title.
func (m model) doing(s Seat) string {
	if f := strings.TrimSpace(clean(s.Focus)); f != "" {
		return f
	}
	return m.titles[s.Addr]
}

// wrapLines word-wraps s into at most n lines of width w, with … if cut.
func wrapLines(s string, w, n int) []string {
	words := strings.Fields(s)
	var lines []string
	cur := ""
	for i, wd := range words {
		if len([]rune(wd)) > w {
			wd = string([]rune(wd)[:w-1]) + "…"
		}
		switch {
		case cur == "":
			cur = wd
		case len([]rune(cur))+1+len([]rune(wd)) <= w:
			cur += " " + wd
		default:
			lines = append(lines, cur)
			cur = wd
		}
		if len(lines) == n {
			last := []rune(lines[n-1])
			if len(last) >= w {
				last = last[:w-1]
			}
			lines[n-1] = string(last) + "…"
			_ = i
			return lines
		}
	}
	if cur != "" {
		lines = append(lines, cur)
	}
	if len(lines) > n {
		lines = lines[:n]
	}
	return lines
}
