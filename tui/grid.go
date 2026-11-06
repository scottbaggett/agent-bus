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
	tileInner = 14 // avatar (8) centered, names truncated to this
	tileW     = tileInner + 2
	tileH     = 8 // border + avatar(4) + name + age
	tileGap   = 1
)

type tile struct {
	seat Seat
	peer string // the Mac it's on, "" for this one
}

type laneGroup struct {
	name   string
	tiles  []int
	needs  int
	latest int64
}

// needsYou counts, per agent, what it is waiting on you for: questions to
// @lead and the attention items that name it.
func (m model) needsYou() map[string]int {
	out := map[string]int{}
	if m.snap == nil {
		return out
	}
	seen := map[string]bool{}
	for _, a := range m.snap.Attention {
		if a.Kind == "needs-you" && a.From != "" && !seen[a.ID] {
			seen[a.ID] = true
			out[a.From]++
		}
	}
	for _, it := range m.snap.Open {
		if it.Gone || it.Stale || seen[it.ID] || !toYou(it.To) {
			continue
		}
		seen[it.ID] = true
		out[it.From]++
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
	byLane := map[string]*laneGroup{}
	var order []string
	for i, t := range all {
		l := t.seat.Lane
		g := byLane[l]
		if g == nil {
			g = &laneGroup{name: l}
			byLane[l] = g
			order = append(order, l)
		}
		g.tiles = append(g.tiles, i)
		g.needs += needs[t.seat.Addr]
		if t.seat.Epoch > g.latest {
			g.latest = t.seat.Epoch
		}
	}
	sort.SliceStable(order, func(i, j int) bool {
		a, b := byLane[order[i]], byLane[order[j]]
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
		g := byLane[l]
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
			name = "no lane"
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
				cells = append(cells, m.renderTile(tiles[ti], m.pane == paneAgents && ti == cur, needs[tiles[ti].seat.Addr]))
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
	idle := m.snap.Now-s.Epoch > 30*60
	color := lipgloss.Color(avatarColor(toolOf(s)))
	av := lipgloss.NewStyle().Foreground(color)
	if idle && !selected {
		av = sDim
	}
	art := av.Render(strings.Join(avatarRows(s.Addr, toolOf(s)), "\n"))
	art = lipgloss.PlaceHorizontal(tileInner, lipgloss.Center, art)

	// Name: the worktree and instance, since the lane is the header.
	name := s.Addr
	if i := strings.IndexByte(name, '/'); i >= 0 {
		name = name[i+1:]
	}
	nameSt := sText
	if selected {
		nameSt = lipgloss.NewStyle().Foreground(cAccent).Bold(true)
	}
	meta := ago(m.snap.Now, s.Epoch)
	if t.peer != "" {
		meta = t.peer + " · " + meta
	}
	metaLine := sDim.Render(meta)
	if needs > 0 {
		metaLine = lipgloss.NewStyle().Foreground(cBad).Bold(true).Render(fmt.Sprintf("● %d for you", needs))
	}
	body := art + "\n" +
		lipgloss.PlaceHorizontal(tileInner, lipgloss.Center, nameSt.Render(midFit(clean(name), tileInner))) + "\n" +
		lipgloss.PlaceHorizontal(tileInner, lipgloss.Center, ansiFitStyled(metaLine, tileInner))

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
	return lipgloss.NewStyle().Border(border).BorderForeground(bc).Width(tileInner).Render(body)
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
func ansiFitStyled(s string, w int) string {
	if lipgloss.Width(s) <= w {
		return s
	}
	return fit(s, w)
}

// gridBody renders the grid into h lines, scrolled to keep the selection in view.
func (m model) gridBody(w, h int) string {
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
	end := min(len(lines), off+h)
	return strings.Join(lines[off:end], "\n")
}

// selectedLine describes the selected agent in one line.
func (m model) selectedLine(w int) string {
	t, ok := m.selectedTile()
	if !ok {
		return ""
	}
	s := t.seat
	parts := []string{lipgloss.NewStyle().Foreground(lipgloss.Color(avatarColor(toolOf(s)))).Bold(true).Render(clean(s.Addr))}
	if t.peer != "" {
		parts = append(parts, "on "+t.peer)
	}
	if s.Repo != "" && s.Repo != "-" {
		parts = append(parts, clean(s.Repo))
	}
	if s.Branch != "" && s.Branch != "-" {
		parts = append(parts, clean(s.Branch))
	}
	parts = append(parts, "seen "+ago(m.snap.Now, s.Epoch)+" ago")
	if n := m.needsYou()[s.Addr]; n > 0 {
		parts = append(parts, lipgloss.NewStyle().Foreground(cBad).Bold(true).Render(fmt.Sprintf("%d waiting on you", n)))
	}
	return fit(strings.Join(parts, sDim.Render(" · ")), w)
}
