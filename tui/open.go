package main

import (
	"os"
	"os/exec"
	"strconv"

	tea "github.com/charmbracelet/bubbletea"
)

// "Open in…": the agent's folder in the apps you have, and its ports in a browser.

type openItem struct {
	label string
	run   func() error
}

func appInstalled(name string) bool {
	for _, d := range []string{"/Applications", homeDir() + "/Applications"} {
		if _, err := os.Stat(d + "/" + name + ".app"); err == nil {
			return true
		}
	}
	return false
}

func openWith(app, dir string) func() error {
	return func() error { return exec.Command("open", "-a", app, dir).Start() }
}

func (m model) openItemsFor(t tile) []openItem {
	var items []openItem
	dir := t.seat.Cwd
	if dir != "" && t.peer == "" {
		if _, err := os.Stat(dir); err == nil {
			items = append(items, openItem{"Finder", func() error { return exec.Command("open", dir).Start() }})
			if ed := getenv("AGENT_BUS_EDITOR"); ed != "" {
				items = append(items, openItem{ed, func() error { return openEditor(dir) }})
			}
			for _, app := range []string{"Zed", "Cursor", "Visual Studio Code", "Windsurf", "Xcode"} {
				if appInstalled(app) {
					items = append(items, openItem{app, openWith(app, dir)})
				}
			}
			for _, app := range []string{"Ghostty", "iTerm", "Warp", "Terminal"} {
				if appInstalled(app) || app == "Terminal" {
					items = append(items, openItem{app, openWith(app, dir)})
					break
				}
			}
		}
	}
	for _, s := range m.servicesFor(t.seat) {
		u := "http://localhost:" + strconv.Itoa(s.Port)
		items = append(items, openItem{"Browser  " + u + "  (" + clean(s.Cmd) + ")", func() error { return openURL(u) }})
	}
	return items
}

func (m model) startOpen(t tile) (tea.Model, tea.Cmd) {
	m.openItems, m.openSel = m.openItemsFor(t), 0
	if len(m.openItems) == 0 {
		if t.peer != "" {
			m.setStatus("it's on " + t.peer + ": open it there")
		} else {
			m.setStatus("nothing to open: no folder on this Mac and no ports")
		}
		return m, nil
	}
	m.mode = modeOpen
	return m, nil
}

func (m model) openKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch s := k.String(); s {
	case "esc", "q", "o":
		m.mode = modePanel
	case "up", "k":
		if m.openSel > 0 {
			m.openSel--
		}
	case "down", "j":
		if m.openSel < len(m.openItems)-1 {
			m.openSel++
		}
	case "enter":
		return m.runOpen(m.openSel)
	default:
		if n, err := strconv.Atoi(s); err == nil && n >= 1 && n <= len(m.openItems) {
			return m.runOpen(n - 1)
		}
	}
	return m, nil
}

func (m model) runOpen(i int) (tea.Model, tea.Cmd) {
	it := m.openItems[i]
	m.mode = modePanel
	if err := it.run(); err != nil {
		m.setStatus("✗ could not open " + it.label + ": " + err.Error())
	} else {
		m.setStatus("✓ opened in " + it.label)
	}
	return m, nil
}
