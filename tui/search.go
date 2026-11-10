package main

import (
	"strings"
	"unicode"

	tea "github.com/charmbracelet/bubbletea"
)

// "/" filters the grid as you type. Every word you type must start a word in
// one of the agent's own fields (name, focus, session title, ticket, branch,
// worktree, lane, ports, Mac), or spell the name's initials ("bm" for Bold
// Mantis). Fields every agent shares, like the repo or the tool, are left out
// so a filter actually narrows the list.

func (m model) haystack(t tile) []string {
	s := t.seat
	h := []string{friendlyName(s.Addr), m.doing(s), m.titles[s.Addr], s.Branch, worktreeOf(s.Addr), s.Lane, t.peer, ports(m.servicesFor(s))}
	if s.Focus != "" {
		h = append(h, s.Focus)
	}
	if t.gone {
		h = append(h, "not running")
	}
	if len(m.needs()[s.Addr]) > 0 {
		h = append(h, "needs you")
	}
	return h
}

// worktreeOf is the folder part of an address: claude/salt-mobile.0726 → salt-mobile.
func worktreeOf(addr string) string {
	_, rest, ok := strings.Cut(addr, "/")
	if !ok {
		return ""
	}
	if i := strings.LastIndexByte(rest, '.'); i > 0 {
		rest = rest[:i]
	}
	return rest
}

func (m model) matches(t tile, q string) bool {
	hay := m.haystack(t)
	name := strings.ToLower(friendlyName(t.seat.Addr))
	for _, term := range strings.Fields(strings.ToLower(q)) {
		ok := initials(name, term)
		for _, f := range hay {
			if ok {
				break
			}
			ok = wordPrefix(strings.ToLower(f), term)
		}
		if !ok {
			return false
		}
	}
	return true
}

// wordPrefix: the term starts a word of hay ("inv" → "invoices", "9473" →
// "salt-9473", "3003" → ":3003"), or, with punctuation in it, appears whole
// ("salt-mobile").
func wordPrefix(hay, term string) bool {
	if term == "" {
		return true
	}
	if strings.IndexFunc(term, isSep) >= 0 {
		return strings.Contains(hay, term)
	}
	for _, w := range strings.FieldsFunc(hay, isSep) {
		if strings.HasPrefix(w, term) {
			return true
		}
	}
	return false
}

func isSep(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) }

// initials: the term's letters start the name's words in order ("bm" → Bold Mantis).
func initials(name, term string) bool {
	if len(term) < 2 {
		return false
	}
	var first []byte
	for _, w := range strings.Fields(name) {
		first = append(first, w[0])
	}
	return strings.HasPrefix(string(first), term)
}

func (m model) searchKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch k.String() {
	case "esc":
		m.query = ""
		m.mode = modeNormal
		m.input.Blur()
		m.cursor[paneAgents] = 0
		return m, nil
	case "enter":
		m.input.Blur()
		m.mode = modeNormal
		if tiles, _ := m.tiles(); len(tiles) > 0 {
			return m.openPanel()
		}
		return m, nil
	case "up", "down", "left", "right":
		dx, dy := 0, 0
		switch k.String() {
		case "up":
			dy = -1
		case "down":
			dy = 1
		case "left":
			dx = -1
		case "right":
			dx = 1
		}
		m.moveGrid(dx, dy, m.gridW())
		return m, nil
	}
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(k)
	if v := m.input.Value(); v != m.query {
		m.query = v
		m.cursor[paneAgents] = 0
	}
	return m, cmd
}

func (m model) startSearch() (tea.Model, tea.Cmd) {
	m.mode = modeSearch
	m.input.Placeholder = "name, focus, ticket, branch, port…"
	m.input.SetValue(m.query)
	m.input.CursorEnd()
	m.input.Width = 40
	m.input.Focus()
	return m, nil
}
