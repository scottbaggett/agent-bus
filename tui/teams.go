package main

import (
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// The teams view, the default: one row per agent, grouped by who it works
// for. A PM's team holds every agent on its lane or on a ticket it names; then
// one group per lane or ticket, even with one agent; then agents on no ticket,
// by repo. Each row leads with how long ago the agent was seen, then its seat,
// then what it's doing. Agents idle for long are folded into one line, so the
// screen shows what is moving.

const staleAfter = 90 * 60 // seconds without a sign of life before a row folds

type team struct {
	key    string
	title  string
	sub    string
	pm     int   // tile index of the team's PM, -1 if none
	rows   []int // tile indexes shown as rows
	idle   []int // tile indexes folded into one line
	needs  int
	latest int64
	kind   int // 0 PM team, 1 lane or ticket, 2 repo
}

var mentionRe = regexp.MustCompile(`(?i)\b([a-z]{2,10})-(\d{1,6})\b|\b(\d{3,6})\b`)

// mentionedTickets reads the tickets a line names, including the bare numbers
// of a list: "SALT-9936, 9935" names SALT-9936 and SALT-9935.
func mentionedTickets(s string) []string {
	var out []string
	prefix := ""
	for _, mm := range mentionRe.FindAllStringSubmatch(s, -1) {
		switch {
		case mm[1] != "":
			prefix = strings.ToUpper(mm[1])
			out = append(out, prefix+"-"+mm[2])
		case prefix != "":
			out = append(out, prefix+"-"+mm[3])
		}
	}
	return out
}

// isPM says whether a seat leads others: it is a lane's PM, holds a PM role,
// or its focus says so.
func (m model) isPM(s Seat) bool {
	for _, l := range m.snap.Lanes {
		if l.PM != "" && l.PM == s.Addr {
			return true
		}
	}
	for _, roles := range m.snap.Roles {
		for role, addr := range roles {
			if addr == s.Addr && (role == "pm" || strings.HasSuffix(role, "-pm")) {
				return true
			}
		}
	}
	return pmFocusRe.MatchString(s.Focus)
}

var pmFocusRe = regexp.MustCompile(`^\s*PM\b`)

func laneKey(s Seat) string {
	if l := strings.ToLower(strings.TrimSpace(s.Lane)); l != "" && l != "unfiled" {
		return l
	}
	return ""
}

func (m model) stale(t tile) bool {
	return t.gone || m.snap.Now-t.seat.Epoch > staleAfter
}

// teams groups the tiles. With showIdle, nothing folds.
func (m model) teams(tiles []tile) ([]team, []int) {
	needs := m.needsYou()
	byKey := map[string]*team{}
	var order []string
	get := func(key, title string, kind int) *team {
		t := byKey[key]
		if t == nil {
			t = &team{key: key, title: title, pm: -1, kind: kind}
			byKey[key] = t
			order = append(order, key)
		}
		return t
	}
	home := make([]string, len(tiles))

	// PMs first: each claims its lane and the tickets it names.
	claims := map[string]string{} // lane or ticket (lower case) -> PM team key
	for i, t := range tiles {
		if !m.isPM(t.seat) {
			continue
		}
		key := "pm:" + t.seat.Addr
		title := laneKey(t.seat)
		if title == "" {
			title = "team"
		}
		tm := get(key, title, 0)
		tm.pm = i
		tm.sub = "PM " + friendlyName(t.seat.Addr)
		home[i] = key
		if l := laneKey(t.seat); l != "" {
			claims[l] = key
		}
		for _, tk := range mentionedTickets(t.seat.Focus) {
			claims[strings.ToLower(tk)] = key
		}
	}
	for _, l := range m.snap.Lanes {
		if l.PM != "" {
			if _, ok := byKey["pm:"+l.PM]; ok {
				claims[strings.ToLower(l.Lane)] = "pm:" + l.PM
			}
		}
	}
	// A PM's team also holds the agents it messages directly, session to session.
	byAddr := map[string]int{}
	for i, t := range tiles {
		byAddr[t.seat.Addr] = i
	}
	for i, t := range tiles {
		if home[i] == "" || !strings.HasPrefix(home[i], "pm:") || byKey[home[i]].pm != i {
			continue
		}
		for _, e := range m.ctx[t.seat.Addr].Events {
			if e.Kind != "msg-in" && e.Kind != "msg-out" {
				continue
			}
			if j, ok := byAddr[m.seatNamed(e.Who)]; ok && home[j] == "" {
				home[j] = home[i]
			}
		}
	}
	for i, t := range tiles {
		if home[i] != "" {
			continue
		}
		lane, tk := laneKey(t.seat), strings.ToLower(ticketOf(t.seat))
		switch {
		case claims[lane] != "":
			home[i] = claims[lane]
		case claims[tk] != "":
			home[i] = claims[tk]
		case lane != "":
			home[i] = "lane:" + lane
			get(home[i], lane, 1)
		case tk != "":
			home[i] = "lane:" + tk
			get(home[i], tk, 1)
		}
	}
	// Agents on no ticket join whoever they talk with, else their repo.
	idx := map[string]int{}
	for i, t := range tiles {
		idx[t.seat.Addr] = i
	}
	for _, e := range m.snap.Recent {
		if e.Kind != "msg" {
			continue
		}
		a, ok1 := idx[e.From]
		b, ok2 := idx[m.resolve(e.To)]
		if !ok1 || !ok2 {
			continue
		}
		if home[a] == "" && home[b] != "" {
			home[a] = home[b]
		} else if home[b] == "" && home[a] != "" {
			home[b] = home[a]
		}
	}
	for i, t := range tiles {
		if home[i] != "" {
			continue
		}
		repo := strings.TrimSpace(t.seat.Repo)
		if repo == "" || repo == "-" {
			home[i] = "repo:"
			get(home[i], "no repo", 2)
			continue
		}
		home[i] = "repo:" + repo
		get(home[i], repo, 2).sub = "no ticket"
	}

	var folded []int
	for i, t := range tiles {
		tm := byKey[home[i]]
		tm.needs += needs[t.seat.Addr]
		if !m.stale(t) {
			tm.latest = max(tm.latest, t.seat.Epoch)
		}
		if i == tm.pm {
			continue
		}
		if m.stale(t) && needs[t.seat.Addr] == 0 && !m.showIdle {
			tm.idle = append(tm.idle, i)
		} else {
			tm.rows = append(tm.rows, i)
		}
	}
	var out []team
	for _, k := range order {
		tm := byKey[k]
		// The PM leads its rows, unless it too has gone quiet.
		if tm.pm >= 0 {
			if m.stale(tiles[tm.pm]) && needs[tiles[tm.pm].seat.Addr] == 0 && !m.showIdle {
				tm.idle = append(tm.idle, tm.pm)
			} else {
				tm.rows = append([]int{tm.pm}, tm.rows...)
			}
		}
		rest := tm.rows
		if tm.pm >= 0 && len(rest) > 0 && rest[0] == tm.pm {
			rest = rest[1:]
		}
		sort.SliceStable(rest, func(i, j int) bool {
			a, b := tiles[rest[i]].seat, tiles[rest[j]].seat
			if (needs[a.Addr] > 0) != (needs[b.Addr] > 0) {
				return needs[a.Addr] > 0
			}
			return a.Epoch > b.Epoch
		})
		sort.SliceStable(tm.idle, func(i, j int) bool { return tiles[tm.idle[i]].seat.Epoch > tiles[tm.idle[j]].seat.Epoch })
		if len(tm.rows) == 0 {
			folded = append(folded, tm.idle...)
			continue
		}
		out = append(out, *tm)
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if (a.needs > 0) != (b.needs > 0) {
			return a.needs > 0
		}
		if a.kind != b.kind {
			return a.kind < b.kind
		}
		return a.latest > b.latest
	})
	return out, folded
}

// spark is an agent's messages over the last two hours, in 15-minute bars,
// on one scale for every agent so rows compare.
func (m model) sparks() (map[string][8]int, int) {
	out := map[string][8]int{}
	top := 0
	add := func(addr string, b int) {
		v := out[addr]
		v[b]++
		out[addr] = v
		top = max(top, v[b])
	}
	for _, e := range m.snap.Recent {
		age := m.snap.Now - e.Epoch
		if e.Kind != "msg" || age < 0 || age >= 8*900 {
			continue
		}
		b := 7 - int(age/900)
		add(e.From, b)
		if to := m.resolve(e.To); to != "" && to != e.From {
			add(to, b)
		}
	}
	return out, top
}

func sparkline(v [8]int, top int) string {
	if top == 0 {
		return ""
	}
	bars := []rune("▁▂▃▄▅▆▇█")
	var b strings.Builder
	any := false
	for _, n := range v {
		if n == 0 {
			b.WriteRune(' ')
			continue
		}
		any = true
		b.WriteRune(bars[min(7, (n*8-1)/top)])
	}
	if !any {
		return ""
	}
	return b.String()
}

// ageStyle: bright under 10 minutes, plain under staleAfter, dim beyond.
func (m model) ageStyle(epoch int64) lipgloss.Style {
	switch d := m.snap.Now - epoch; {
	case d < 10*60:
		return lipgloss.NewStyle().Foreground(cGood).Bold(true)
	case d < staleAfter:
		return sText
	default:
		return sDim
	}
}

// seatLabel is how a seat reads in a row: its address, with the Mac it's on.
func seatLabel(t tile) string {
	if t.peer != "" {
		return t.peer + ":" + clean(t.seat.Addr)
	}
	return clean(t.seat.Addr)
}

type cols struct{ seat, tag, name, spark, ctx int }

func tableCols(w int) cols {
	c := cols{seat: min(44, max(20, w/4)), tag: 10, name: 15, spark: 9, ctx: 10}
	if w < 130 {
		c.name = 0
	}
	if w < 110 {
		c.spark = 0
	}
	if w < 70 {
		c.ctx, c.tag = 0, 0
	}
	return c
}

// row is one agent in one line.
func (m model) row(t tile, w int, c cols, selected, isPM bool, needs int, spark string) string {
	s := t.seat
	mark := "  "
	if selected {
		mark = sAccent.Render("▌ ")
	}
	badge := "   "
	if needs > 0 {
		badge = lipgloss.NewStyle().Background(cBad).Foreground(lipgloss.Color("#FFFFFF")).Bold(true).Render(fmt.Sprintf("%2d ", needs))
	}
	age := "gone"
	if !t.gone {
		age = ago(m.snap.Now, s.Epoch)
	}
	ageSt := m.ageStyle(s.Epoch)
	if t.gone {
		ageSt = sDim
	}
	seatSt := sText
	if selected {
		seatSt = sAccent
	} else if m.stale(t) {
		seatSt = sDim
	}
	tag := ""
	switch {
	case isPM:
		tag = "PM"
	case ticketOf(s) != "":
		tag = ticketOf(s)
	}
	glyph, tone := " ", "dim"
	if c, ok := m.ctx[s.Addr]; ok && !t.gone {
		glyph, tone = c.glyph(m.snap.Now)
	}
	line := mark + badge + toneStyle(tone).Bold(true).Render(glyph) + ageSt.Render(fmt.Sprintf("%4s", age)) + "  " +
		seatSt.Render(fit(midFit(seatLabel(t), c.seat), c.seat)) + "  " +
		m.ctxCell(s.Addr, c.ctx) +
		sAccent.Render(fit(tag, c.tag))
	if c.name > 0 {
		line += sDim.Render(fit(friendlyName(s.Addr), c.name))
	}
	used := lipgloss.Width(line)
	focusW := w - used - c.spark
	doing := m.doing(s)
	if doing == "" && t.gone {
		doing = "not running"
	}
	if tk := ticketOf(s); tk != "" {
		doing = strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(doing, tk), ":"))
	}
	fs := sText
	if m.stale(t) {
		fs = sDim
	}
	line += fs.Render(fit(doing, max(0, focusW)))
	if c.spark > 0 {
		line += lipgloss.NewStyle().Foreground(cAccent).Render(fit(" "+spark, c.spark))
	}
	return line
}

// rule is a group header: ── title · sub · n ─────.
func rule(text string, w int, st lipgloss.Style) string {
	head := "── " + text + " "
	return st.Render(head) + sDim.Render(strings.Repeat("─", max(0, w-lipgloss.Width(head))))
}

// needsBand lists what waits on you, above everything else.
func (m model) needsBand(w int) []string {
	type row struct {
		n    need
		seat string
	}
	var rows []row
	for addr, ns := range m.needs() {
		for _, n := range ns {
			rows = append(rows, row{n, addr})
		}
	}
	if len(rows) == 0 {
		return nil
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].n.Epoch > rows[j].n.Epoch })
	bad := lipgloss.NewStyle().Foreground(cBad).Bold(true)
	out := []string{rule(fmt.Sprintf("NEEDS YOU · %d", len(rows)), w-12, bad) + sDim.Render(" n: next ──")}
	for i, r := range rows {
		if i == 5 {
			out = append(out, sDim.Render(fmt.Sprintf("     + %d more · n moves through them", len(rows)-5)))
			break
		}
		line := "     " + kindStyle(r.n.State).Render(fit(r.n.State, 13)) + sDim.Render(fmt.Sprintf("%4s  ", ago(m.snap.Now, r.n.Epoch))) +
			sText.Render(fit(midFit(clean(r.seat), 36), 36)) + "  " + clean(r.n.Subject)
		out = append(out, fit(line, w))
	}
	return append(out, "")
}

// teamsLayout renders the teams view and says where each agent's row is.
func (m model) teamsLayout(w int) ([]string, []placed) {
	tiles, _ := m.tiles()
	if len(tiles) == 0 {
		return []string{sDim.Render("no agents running")}, nil
	}
	pos := make([]placed, len(tiles))
	teams, folded := m.teams(tiles)
	needs := m.needsYou()
	cur := m.cursor[paneAgents]
	c := tableCols(w)
	sp, top := m.sparks()

	lines := m.needsBand(w)
	head := "      " + fmt.Sprintf("%4s", "seen") + "  " + fit("seat", c.seat) + "  " + fit("context", c.ctx) + fit("ticket", c.tag)
	if c.name > 0 {
		head += fit("name", c.name)
	}
	head += fit("doing", max(0, w-lipgloss.Width(head)-c.spark))
	if c.spark > 0 {
		head += fit(" msgs 2h", c.spark)
	}
	lines = append(lines, sDim.Render(head))

	for _, tm := range teams {
		title := tm.title
		if tm.sub != "" {
			title += " · " + tm.sub
		}
		title += fmt.Sprintf(" · %d", len(tm.rows)+len(tm.idle))
		st := sAccent
		if tm.needs > 0 {
			st = lipgloss.NewStyle().Foreground(cBad).Bold(true)
		} else if tm.kind == 2 {
			st = sHeader
		}
		lines = append(lines, rule(clean(title), w, st))
		for _, i := range tm.rows {
			pos[i] = placed{x: 0, y: len(lines), w: w, h: 1}
			lines = append(lines, m.row(tiles[i], w, c, i == cur, i == tm.pm, needs[tiles[i].seat.Addr], sparkline(sp[tiles[i].seat.Addr], top)))
		}
		if len(tm.idle) > 0 {
			var names []string
			for _, i := range tm.idle {
				names = append(names, midFit(seatLabel(tiles[i]), 28)+" "+ago(m.snap.Now, tiles[i].seat.Epoch))
			}
			lines = append(lines, sDim.Render(fit(fmt.Sprintf("            + %d idle: %s", len(tm.idle), strings.Join(names, " · ")), w)))
		}
	}
	if len(folded) > 0 {
		count := map[string]int{}
		var keys []string
		for _, i := range folded {
			k := strings.TrimSpace(tiles[i].seat.Repo)
			if k == "" || k == "-" {
				k = toolOf(tiles[i].seat)
			}
			if count[k] == 0 {
				keys = append(keys, k)
			}
			count[k]++
		}
		sort.SliceStable(keys, func(i, j int) bool { return count[keys[i]] > count[keys[j]] })
		var parts []string
		for _, k := range keys {
			parts = append(parts, fmt.Sprintf("%s ×%d", clean(k), count[k]))
		}
		lines = append(lines, "", sDim.Render(fit(fmt.Sprintf("── idle over %dm · %d agents · %s  ", staleAfter/60, len(folded), strings.Join(parts, " · ")), w-14))+sDim.Render(" z: show ──"))
	}
	if m.showIdle {
		lines = append(lines, "", sDim.Render("showing idle agents · z: fold them"))
	}
	for i := range lines {
		lines[i] = fit(lines[i], w)
	}
	return lines, pos
}

// ctxCell is how full an agent's context window is: ▰▰▰▱▱ 62%.
func (m model) ctxCell(addr string, w int) string {
	if w == 0 {
		return ""
	}
	c, ok := m.ctx[addr]
	pct := -1
	if ok {
		pct = c.ctxPct()
	}
	if pct < 0 {
		return strings.Repeat(" ", w)
	}
	return toneStyle(ctxTone(pct)).Render(fit(meter(pct, 4)+fmt.Sprintf(" %d%%", pct), w))
}
