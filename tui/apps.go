package main

import (
	"bufio"
	"bytes"
	"context"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// Each agent runs inside some app: Claude, Ghostty, Cursor, Zed… Walking up
// from the agent's process to the outermost .app bundle finds it, so one click
// brings that app (and that instance of it) to the front.

type hostApp struct {
	Name string // "Claude", "Ghostty"
	Path string // /Applications/Claude.app
	PID  int    // the app's own process, so two copies of an app stay apart
}

type appsMsg map[string]hostApp // addr -> app

func scanAppsCmd(seats []Seat) tea.Cmd {
	want := map[string]int{}
	for _, s := range seats {
		if s.PID > 0 {
			want[s.Addr] = s.PID
		}
	}
	return func() tea.Msg { return appsMsg(scanApps(want)) }
}

func scanApps(want map[string]int) map[string]hostApp {
	out := map[string]hostApp{}
	if len(want) == 0 {
		return out
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	b, err := exec.CommandContext(ctx, "ps", "-axo", "pid=,ppid=,comm=").Output()
	if err != nil {
		return out
	}
	type proc struct {
		ppid int
		comm string
	}
	procs := map[int]proc{}
	sc := bufio.NewScanner(bytes.NewReader(b))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 3 {
			continue
		}
		pid, e1 := strconv.Atoi(f[0])
		ppid, e2 := strconv.Atoi(f[1])
		if e1 != nil || e2 != nil {
			continue
		}
		_, rest, _ := strings.Cut(strings.TrimSpace(sc.Text()), f[0])
		_, comm, _ := strings.Cut(strings.TrimSpace(rest), f[1])
		procs[pid] = proc{ppid, strings.TrimSpace(comm)}
	}
	for addr, pid := range want {
		var app hostApp
		for i, p := 0, pid; i < 40 && p > 1; i++ {
			pr, ok := procs[p]
			if !ok {
				break
			}
			if j := strings.Index(pr.comm, ".app/"); j >= 0 {
				path := pr.comm[:j+4]
				// Keep climbing: the outermost bundle is the app you see
				// (Claude Code's own CLI ships as a small claude.app inside it).
				app = hostApp{Name: strings.TrimSuffix(filepath.Base(path), ".app"), Path: path, PID: p}
			}
			p = pr.ppid
		}
		if app.Path != "" {
			out[addr] = app
		}
	}
	return out
}

// focusApp brings the agent's app to the front: that exact process when
// macOS allows it, else the app by path.
func focusApp(a hostApp) error {
	script := `tell application "System Events" to set frontmost of (first process whose unix id is ` + strconv.Itoa(a.PID) + `) to true`
	if err := exec.Command("osascript", "-e", script).Run(); err == nil {
		return nil
	}
	return exec.Command("open", a.Path).Run()
}

type appFocused struct {
	name string
	err  error
}

func focusAppCmd(a hostApp) tea.Cmd {
	return func() tea.Msg { return appFocused{a.Name, focusApp(a)} }
}

func (m model) appOf(t tile) (hostApp, bool) {
	if t.peer != "" || t.gone {
		return hostApp{}, false
	}
	a, ok := m.apps[t.seat.Addr]
	return a, ok
}

// jumpToApp brings the panel's agent's app forward.
func (m model) jumpToApp() (tea.Model, tea.Cmd) {
	t := m.panel
	a, ok := m.appOf(t)
	switch {
	case ok:
		m.setStatus("→ " + a.Name + " · " + friendlyName(t.seat.Addr))
		return m, focusAppCmd(a)
	case t.peer != "":
		m.setStatus(friendlyName(t.seat.Addr) + " runs on " + t.peer)
	case t.gone:
		m.setStatus(friendlyName(t.seat.Addr) + " has exited")
	default:
		m.setStatus("can't tell which app " + friendlyName(t.seat.Addr) + " runs in")
	}
	return m, nil
}
