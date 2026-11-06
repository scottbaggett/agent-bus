package main

import (
	"strings"
	"unicode"

	tea "github.com/charmbracelet/bubbletea"
)

// "/" filters the grid as you type. Every word you type must match one of an
// agent's fields, either as a substring or fuzzily (its letters in order).

func (m model) haystack(t tile) []string {
	s := t.seat
	h := []string{friendlyName(s.Addr), s.Addr, s.Tool, m.doing(s), workingOn(s), s.Branch, s.Lane, s.Repo, t.peer, ports(m.servicesFor(s))}
	if t.gone {
		h = append(h, "not running")
	}
	if len(m.needs()[s.Addr]) > 0 {
		h = append(h, "needs you")
	}
	return h
}

func (m model) matches(t tile, q string) bool {
	hay := m.haystack(t)
	for _, term := range strings.Fields(strings.ToLower(q)) {
		ok := false
		for _, f := range hay {
			if fuzzy(strings.ToLower(f), term) {
				ok = true
				break
			}
		}
		if !ok {
			return false
		}
	}
	return true
}

// fuzzy: a substring, or the term's letters in order where each one starts a
// word or follows the previous match (so "bm" finds Bold Mantis, "inv" finds
// "invoices", but "ae" does not match everything).
func fuzzy(hay, term string) bool {
	if term == "" || strings.Contains(hay, term) {
		return true
	}
	h, t := []rune(hay), []rune(term)
	j := 0
	prev := -2
	for i := 0; i < len(h) && j < len(t); i++ {
		if h[i] != t[j] {
			continue
		}
		start := i == 0 || !unicode.IsLetter(h[i-1]) && !unicode.IsDigit(h[i-1])
		if start || i == prev+1 {
			prev = i
			j++
		}
	}
	return j == len(t)
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
