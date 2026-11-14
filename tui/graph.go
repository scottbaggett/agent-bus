package main

import (
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// The graph view: agents that work together drawn as one cluster, joined by
// lines. Two agents are joined when one messaged the other, when they share a
// lane (joined through its PM), or when they are on the same ticket. Agents
// joined to no one sit together under "on their own".

const (
	chipInner = 20
	chipW     = chipInner + 2
	chipH     = 4 // border + name + what it's doing
)

type gedge struct {
	a, b int // tile indexes, a < b
	msgs int // messages between them; 0 means joined by lane or ticket only
}

type cluster struct {
	name   string
	nodes  []int // tile indexes, hub first
	edges  []gedge
	pm     string // lane PM's address, if one is in the cluster
	needs  int
	latest int64
}

// ticketOf is the ticket an agent is on, from its branch, lane or focus; ""
// when none names one.
func ticketOf(s Seat) string {
	for _, v := range []string{s.Branch, s.Lane, s.Focus} {
		if mm := ticketRe.FindStringSubmatch(v); mm != nil {
			return strings.ToUpper(mm[1]) + "-" + mm[2]
		}
	}
	return ""
}

// resolve turns a packet's recipient into a seat address: an address as is,
// or a role (@tools-pm) through the bus's role table. Broadcasts and you
// (@lead) resolve to nothing.
func (m model) resolve(to string) string {
	if !strings.HasPrefix(to, "@") {
		return to
	}
	role := strings.TrimPrefix(to, "@")
	for _, roles := range m.snap.Roles {
		if a, ok := roles[role]; ok {
			return a
		}
	}
	return ""
}

// seatNamed finds the seat a Claude session name refers to: its worktree
// ("salt-9938" is claude/salt-9938.efc0), or its full address.
func (m model) seatNamed(name string) string {
	if name == "" {
		return ""
	}
	match := ""
	for _, s := range m.snap.Seats {
		if s.Addr == name {
			return s.Addr
		}
		wt := s.Addr
		if i := strings.IndexByte(wt, '/'); i >= 0 {
			wt = wt[i+1:]
		}
		if i := strings.LastIndexByte(wt, '.'); i >= 0 {
			wt = wt[:i]
		}
		short := strings.TrimPrefix(strings.TrimPrefix(wt, "feature-"), "claude-")
		if wt == name || short == name || strings.HasPrefix(short, name+"-") {
			if match != "" {
				return "" // two seats share it: don't guess
			}
			match = s.Addr
		}
	}
	return match
}

// graph groups the tiles into clusters of agents joined to each other, and
// the agents joined to no one.
func (m model) graph(tiles []tile) ([]cluster, []int) {
	idx := map[string]int{}
	for i, t := range tiles {
		idx[t.seat.Addr] = i
	}
	type key struct{ a, b int }
	edges := map[key]*gedge{}
	join := func(a, b int, msg bool) {
		if a == b {
			return
		}
		if a > b {
			a, b = b, a
		}
		e := edges[key{a, b}]
		if e == nil {
			e = &gedge{a: a, b: b}
			edges[key{a, b}] = e
		}
		if msg {
			e.msgs++
		}
	}

	// Messages, recent and still open.
	seen := map[string]bool{}
	talk := func(id, from, to string) {
		if seen[id] {
			return
		}
		seen[id] = true
		a, ok1 := idx[from]
		b, ok2 := idx[m.resolve(to)]
		if ok1 && ok2 {
			join(a, b, true)
		}
	}
	for _, e := range m.snap.Recent {
		if e.Kind == "msg" {
			talk(e.ID, e.From, e.To)
		}
	}
	for _, it := range m.snap.Open {
		if !it.Stale {
			talk(it.ID, it.From, it.To)
		}
	}
	// Messages between Claude sessions, from their transcripts.
	for addr, c := range m.ctx {
		a, ok := idx[addr]
		if !ok {
			continue
		}
		for _, e := range c.Events {
			if e.Kind != "msg-in" && e.Kind != "msg-out" {
				continue
			}
			if b, ok := idx[m.seatNamed(e.Who)]; ok {
				join(a, b, true)
			}
		}
	}

	// A lane joins its agents through its PM, else through its first agent.
	pms := map[string]string{}
	for _, l := range m.snap.Lanes {
		if l.PM != "" {
			pms[l.Lane] = l.PM
		}
	}
	star := func(group map[string][]int, hubs map[string]string) {
		for k, members := range group {
			if len(members) < 2 && hubs[k] == "" {
				continue
			}
			hub := members[0]
			if h, ok := idx[hubs[k]]; ok {
				hub = h
			}
			for _, i := range members {
				join(hub, i, false)
			}
		}
	}
	lanes, tickets := map[string][]int{}, map[string][]int{}
	for i, t := range tiles {
		if l := t.seat.Lane; l != "" && l != "unfiled" {
			lanes[l] = append(lanes[l], i)
		}
		if tk := ticketOf(t.seat); tk != "" {
			tickets[tk] = append(tickets[tk], i)
		}
	}
	star(lanes, pms)
	star(tickets, nil)

	// Connected components.
	parent := make([]int, len(tiles))
	for i := range parent {
		parent[i] = i
	}
	var find func(int) int
	find = func(i int) int {
		if parent[i] != i {
			parent[i] = find(parent[i])
		}
		return parent[i]
	}
	for k := range edges {
		parent[find(k.a)] = find(k.b)
	}
	comp := map[int]*cluster{}
	var roots []int
	needs := m.needsYou()
	for i, t := range tiles {
		r := find(i)
		c := comp[r]
		if c == nil {
			c = &cluster{}
			comp[r] = c
			roots = append(roots, r)
		}
		c.nodes = append(c.nodes, i)
		c.needs += needs[t.seat.Addr]
		c.latest = max(c.latest, t.seat.Epoch)
	}
	for _, e := range edges {
		c := comp[find(e.a)]
		c.edges = append(c.edges, *e)
	}

	var clusters []cluster
	var solo []int
	for _, r := range roots {
		c := comp[r]
		if len(c.nodes) == 1 {
			solo = append(solo, c.nodes[0])
			continue
		}
		sort.Slice(c.edges, func(i, j int) bool {
			if c.edges[i].a != c.edges[j].a {
				return c.edges[i].a < c.edges[j].a
			}
			return c.edges[i].b < c.edges[j].b
		})
		m.nameCluster(c, tiles, pms)
		clusters = append(clusters, *c)
	}
	sort.SliceStable(clusters, func(i, j int) bool {
		a, b := clusters[i], clusters[j]
		if (a.needs > 0) != (b.needs > 0) {
			return a.needs > 0
		}
		return a.latest > b.latest
	})
	return clusters, solo
}

// nameCluster picks the cluster's hub (its lane PM, else the agent with the
// most ties) and its name (the lane most of it is in, else its ticket, else
// the hub's name).
func (m model) nameCluster(c *cluster, tiles []tile, pms map[string]string) {
	deg := map[int]int{}
	for _, e := range c.edges {
		deg[e.a] += 1 + e.msgs
		deg[e.b] += 1 + e.msgs
	}
	lanes, tickets := map[string]int{}, map[string]int{}
	for _, i := range c.nodes {
		if l := tiles[i].seat.Lane; l != "" && l != "unfiled" {
			lanes[l]++
		}
		if tk := ticketOf(tiles[i].seat); tk != "" {
			tickets[tk]++
		}
	}
	top := func(counts map[string]int) string {
		best, n := "", 0
		for k, v := range counts {
			if v > n || (v == n && k < best) {
				best, n = k, v
			}
		}
		return best
	}
	hub := c.nodes[0]
	for _, i := range c.nodes {
		if deg[i] > deg[hub] {
			hub = i
		}
	}
	lane := top(lanes)
	for _, i := range c.nodes {
		if a := tiles[i].seat.Addr; lane != "" && pms[lane] == a {
			hub, c.pm = i, a
		}
	}
	switch {
	case lane != "":
		c.name = lane
	case top(tickets) != "":
		c.name = top(tickets)
	default:
		c.name = "with " + friendlyName(tiles[hub].seat.Addr)
	}
	// Hub first, the rest by most ties.
	sort.SliceStable(c.nodes, func(i, j int) bool {
		a, b := c.nodes[i], c.nodes[j]
		if (a == hub) != (b == hub) {
			return a == hub
		}
		return deg[a] > deg[b]
	})
}

// ---- layout

// chip is an agent drawn small: its name and what it's doing, in a box.
func (m model) chip(t tile, selected bool, needs int, pm bool) []string {
	s := t.seat
	idle := t.gone || m.snap.Now-s.Epoch > 30*60
	dot := lipgloss.NewStyle().Foreground(colorFor(s)).Render("●")
	if idle && !selected && needs == 0 {
		dot = sDim.Render("○")
	}
	nameSt := sText.Bold(true)
	if selected {
		nameSt = lipgloss.NewStyle().Foreground(cAccent).Bold(true)
	}
	name := friendlyName(s.Addr)
	tag := ""
	if pm {
		tag = sAccent.Render(" pm")
	}
	l1 := fit(dot+" "+nameSt.Render(name)+tag, chipInner)

	l2 := sDim.Render(fit(m.chipDoing(t), chipInner))

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
	out := strings.Split(lipgloss.NewStyle().Border(border).BorderForeground(bc).Width(chipInner).Render(l1+"\n"+l2), "\n")
	if needs > 0 {
		badge := lipgloss.NewStyle().Background(cBad).Foreground(lipgloss.Color("#FFFFFF")).Bold(true).Render(fmt.Sprintf(" %d ", needs))
		bs := lipgloss.NewStyle().Foreground(bc)
		fill := chipInner - lipgloss.Width(badge) - 1
		out[0] = bs.Render(border.TopLeft+strings.Repeat(border.Top, fill)) + badge + bs.Render(border.Top+border.TopRight)
	}
	return out
}

// chipDoing is what an agent is on, in a few words: its ticket and focus,
// else its branch or repo.
func (m model) chipDoing(t tile) string {
	s := t.seat
	doing := m.doing(s)
	if tk := ticketOf(s); tk != "" && !strings.Contains(strings.ToUpper(doing), tk) {
		doing = tk + " " + doing
	}
	switch {
	case t.gone:
		doing = "not running"
	case strings.TrimSpace(doing) == "":
		doing = workingOn(s)
	}
	if doing == "-" {
		doing = ""
	}
	if t.peer != "" {
		doing = strings.TrimSuffix(t.peer+" · "+doing, " · ")
	}
	return strings.TrimSpace(doing)
}

// spread places a cluster's chips: the hub in the middle, the rest on a ring
// around it, the ring growing until no two chips touch. It returns each
// chip's top-left corner and the canvas size, or ok=false if the ring would
// not fit in maxW.
func spread(n, maxW int) (xy [][2]int, w, h int, ok bool) {
	k := n - 1
	rx, ry := float64(chipW+4), float64(chipH+1)
	if k <= 2 {
		ry = 0
	}
	for try := 0; try < 40; try++ {
		pts := make([][2]int, n) // chip centers, hub at 0,0
		for i := 1; i < n; i++ {
			th := math.Pi + 2*math.Pi*float64(i-1)/float64(k)
			pts[i] = [2]int{int(math.Round(rx * math.Cos(th))), int(math.Round(ry * math.Sin(th)))}
		}
		clash := false
		for i := 0; i < n && !clash; i++ {
			for j := i + 1; j < n; j++ {
				if abs(pts[i][0]-pts[j][0]) < chipW+3 && abs(pts[i][1]-pts[j][1]) < chipH+1 {
					clash = true
					break
				}
			}
		}
		if !clash {
			minX, minY, maxX, maxY := 0, 0, 0, 0
			for _, p := range pts {
				minX, maxX = min(minX, p[0]), max(maxX, p[0])
				minY, maxY = min(minY, p[1]), max(maxY, p[1])
			}
			w, h = maxX-minX+chipW, maxY-minY+chipH
			if w > maxW {
				return nil, 0, 0, false
			}
			xy = make([][2]int, n)
			for i, p := range pts {
				xy[i] = [2]int{p[0] - minX, p[1] - minY}
			}
			return xy, w, h, true
		}
		rx += 4
		ry += 1.5
		if k <= 2 {
			ry = 0
		}
	}
	return nil, 0, 0, false
}

// rows places chips in rows, the hub alone on top: for clusters too big for
// a ring.
func rows(n, maxW int) (xy [][2]int, w, h int) {
	cols := max(1, (maxW+2)/(chipW+2))
	cols = min(cols, max(1, n-1))
	w = cols*(chipW+2) - 2
	xy = make([][2]int, n)
	xy[0] = [2]int{(w - chipW) / 2, 0}
	for i := 1; i < n; i++ {
		r, c := (i-1)/cols, (i-1)%cols
		xy[i] = [2]int{c * (chipW + 2), (r + 1) * (chipH + 2)}
	}
	h = ((n-2)/cols+2)*(chipH+2) - 2
	return xy, w, h
}

// canvas holds the lines between chips: one rune and one ink per cell.
type canvas struct {
	w, h int
	r    [][]rune
	ink  [][]uint8 // 0 empty, 1 shared lane or ticket, 2 messages
}

func newCanvas(w, h int) *canvas {
	c := &canvas{w: w, h: h, r: make([][]rune, h), ink: make([][]uint8, h)}
	for y := range c.r {
		c.r[y] = make([]rune, w)
		c.ink[y] = make([]uint8, w)
	}
	return c
}

// line draws from one point to another. Message ties are solid, shaped to
// their slope; lane and ticket ties are dotted.
func (c *canvas) line(x0, y0, x1, y1 int, ink uint8) {
	dx, dy := x1-x0, y1-y0
	ax, ay := abs(dx), abs(dy)*2 // a cell is about twice as tall as wide
	ch := '·'
	if ink == 2 {
		switch {
		case ay*2 < ax:
			ch = '─'
		case ax*2 < ay:
			ch = '│'
		case (dx > 0) == (dy > 0):
			ch = '╲'
		default:
			ch = '╱'
		}
	}
	sx, sy := 1, 1
	if dx < 0 {
		sx = -1
	}
	if dy < 0 {
		sy = -1
	}
	ex, ey := abs(dx), -abs(dy)
	err := ex + ey
	x, y := x0, y0
	for i := 0; ; i++ {
		if x >= 0 && y >= 0 && x < c.w && y < c.h && ink >= c.ink[y][x] && (ink == 2 || i%2 == 0) {
			c.r[y][x], c.ink[y][x] = ch, ink
		}
		if x == x1 && y == y1 {
			return
		}
		e2 := 2 * err
		if e2 >= ey {
			err += ey
			x += sx
		}
		if e2 <= ex {
			err += ex
			y += sy
		}
	}
}

// span renders cells [x0, x1) of a row.
func (c *canvas) span(y, x0, x1 int) string {
	var b strings.Builder
	msg := lipgloss.NewStyle().Foreground(cAccent)
	for x := x0; x < x1; {
		ink := c.ink[y][x]
		end := x
		for end < x1 && c.ink[y][end] == ink {
			end++
		}
		var run strings.Builder
		for i := x; i < end; i++ {
			if c.r[y][i] == 0 {
				run.WriteByte(' ')
			} else {
				run.WriteRune(c.r[y][i])
			}
		}
		switch ink {
		case 0:
			b.WriteString(run.String())
		case 1:
			b.WriteString(sDim.Render(run.String()))
		default:
			b.WriteString(msg.Render(run.String()))
		}
		x = end
	}
	return b.String()
}

// frame boxes lines under a title: ╭─ title · 3 ───╮.
func frame(title string, lines []string, inner int, bc lipgloss.TerminalColor) []string {
	bs := lipgloss.NewStyle().Foreground(bc)
	t := " " + title + " "
	top := bs.Render("╭─") + t + bs.Render(strings.Repeat("─", max(0, inner+1-lipgloss.Width(t)))+"╮")
	out := []string{top}
	for _, l := range lines {
		out = append(out, bs.Render("│")+" "+fit(l, inner)+" "+bs.Render("│"))
	}
	return append(out, bs.Render("╰"+strings.Repeat("─", inner+2)+"╯"))
}

// clusterBlock draws one cluster in its frame and says where each chip went,
// relative to the block's top-left.
func (m model) clusterBlock(c cluster, tiles []tile, maxW int) ([]string, map[int]placed) {
	inner := maxW - 4
	xy, cw, ch, ok := spread(len(c.nodes), inner)
	if !ok {
		xy, cw, ch = rows(len(c.nodes), inner)
	}
	at := map[int]int{} // tile index -> position in c.nodes
	for k, i := range c.nodes {
		at[i] = k
	}
	cv := newCanvas(cw, ch)
	for _, ink := range []uint8{1, 2} { // dotted first, so solid lines win
		for _, e := range c.edges {
			if (e.msgs > 0) != (ink == 2) {
				continue
			}
			a, b := xy[at[e.a]], xy[at[e.b]]
			cv.line(a[0]+chipW/2, a[1]+chipH/2, b[0]+chipW/2, b[1]+chipH/2, ink)
		}
	}
	needs := m.needsYou()
	cur := m.cursor[paneAgents]
	chips := make([][]string, len(c.nodes))
	for k, i := range c.nodes {
		chips[k] = m.chip(tiles[i], i == cur, needs[tiles[i].seat.Addr], tiles[i].seat.Addr == c.pm)
	}
	order := make([]int, len(c.nodes))
	for k := range order {
		order[k] = k
	}
	sort.Slice(order, func(i, j int) bool { return xy[order[i]][0] < xy[order[j]][0] })
	var lines []string
	for y := 0; y < ch; y++ {
		var b strings.Builder
		x := 0
		for _, k := range order {
			p := xy[k]
			if y < p[1] || y >= p[1]+chipH || p[0] < x {
				continue
			}
			b.WriteString(cv.span(y, x, p[0]))
			b.WriteString(chips[k][y-p[1]])
			x = p[0] + chipW
		}
		b.WriteString(cv.span(y, x, cw))
		lines = append(lines, b.String())
	}

	title := sAccent.Render(clean(c.name)) + sDim.Render(fmt.Sprintf(" · %d", len(c.nodes)))
	bc := lipgloss.TerminalColor(cDim)
	if c.needs > 0 {
		title = lipgloss.NewStyle().Foreground(cBad).Bold(true).Render(clean(c.name)+" ●") + sDim.Render(fmt.Sprintf(" · %d", len(c.nodes)))
		bc = cBad
	}
	pos := map[int]placed{}
	for k, i := range c.nodes {
		pos[i] = placed{x: 2 + xy[k][0], y: 1 + xy[k][1], w: chipW, h: chipH}
	}
	return frame(title, lines, cw, bc), pos
}

// soloBlock is the agents tied to no one, one line each, in columns: they
// matter less here than the clusters, so they stay small.
func (m model) soloBlock(solo []int, tiles []tile, maxW int) ([]string, map[int]placed) {
	inner := maxW - 4
	cols := max(1, min(len(solo), (inner+2)/(chipW+2)))
	per := (len(solo) + cols - 1) / cols
	w := cols*(chipW+2) - 2
	needs := m.needsYou()
	cur := m.cursor[paneAgents]
	pos := map[int]placed{}
	grid := make([][]string, per)
	for k, i := range solo {
		c, r := k/per, k%per
		pos[i] = placed{x: 2 + c*(chipW+2), y: 1 + r, w: chipW, h: 1}
		grid[r] = append(grid[r], m.soloLine(tiles[i], i == cur, needs[tiles[i].seat.Addr]))
	}
	var lines []string
	for _, row := range grid {
		lines = append(lines, strings.Join(row, "  "))
	}
	title := sHeader.Render("on their own") + sDim.Render(fmt.Sprintf(" · %d", len(solo)))
	return frame(title, lines, w, cDim), pos
}

// soloLine is an agent in one line: dot, name, what it's on.
func (m model) soloLine(t tile, selected bool, needs int) string {
	s := t.seat
	idle := t.gone || m.snap.Now-s.Epoch > 30*60
	dot := lipgloss.NewStyle().Foreground(colorFor(s)).Render("●")
	if idle && needs == 0 {
		dot = sDim.Render("○")
	}
	name := friendlyName(s.Addr)
	rest := chipW - 2 - lipgloss.Width(name)
	badge := ""
	if needs > 0 {
		badge = fmt.Sprintf(" %d", needs)
		rest -= len(badge)
	}
	on := m.chipDoing(t)
	nameSt, onSt := sText, sDim
	if selected {
		nameSt = sSel.Foreground(cAccent)
		onSt = sSel.Bold(false)
		name = nameSt.Render(name)
		on = onSt.Render(fit(" "+on, rest))
	} else {
		name = nameSt.Render(name)
		on = onSt.Render(fit(" "+on, rest))
	}
	if badge != "" {
		badge = lipgloss.NewStyle().Foreground(cBad).Bold(true).Render(badge)
	}
	return dot + " " + name + badge + on
}

// graphLayout flows the clusters left to right like the lane groups, then the
// agents on their own, and says where each agent landed.
func (m model) graphLayout(w int) ([]string, []placed) {
	tiles, _ := m.tiles()
	if len(tiles) == 0 {
		return []string{sDim.Render("no agents running")}, nil
	}
	clusters, solo := m.graph(tiles)
	pos := make([]placed, len(tiles))

	var lines, shelf []string
	var shelfPos []map[int]placed
	var shelfX []int
	x := 0
	flush := func() {
		if len(shelf) == 0 {
			return
		}
		y0 := len(lines)
		lines = append(lines, strings.Split(lipgloss.JoinHorizontal(lipgloss.Top, shelf...), "\n")...)
		for k, ps := range shelfPos {
			for i, p := range ps {
				pos[i] = placed{x: shelfX[k] + p.x, y: y0 + p.y, w: p.w, h: p.h}
			}
		}
		shelf, shelfPos, shelfX, x = nil, nil, nil, 0
	}
	add := func(block []string, ps map[int]placed) {
		bw := 0
		for _, l := range block {
			bw = max(bw, lipgloss.Width(l))
		}
		gap := 0
		if len(shelf) > 0 {
			gap = 2
		}
		if x+gap+bw > w {
			flush()
			gap = 0
		}
		if gap > 0 {
			shelf = append(shelf, strings.Repeat(" ", gap))
		}
		shelfX = append(shelfX, x+gap)
		shelfPos = append(shelfPos, ps)
		shelf = append(shelf, lipgloss.NewStyle().Width(bw).Render(strings.Join(block, "\n")))
		x += gap + bw
	}
	for _, c := range clusters {
		add(m.clusterBlock(c, tiles, w))
	}
	if len(solo) > 0 {
		flush()
		add(m.soloBlock(solo, tiles, w))
	}
	flush()
	if len(clusters) > 0 {
		lines = append(lines, "", sDim.Render("─── messages   ··· same lane or ticket   g: switch view"))
	}
	return lines, pos
}
