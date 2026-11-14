package main

import (
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

// "Go to it": the terminal the agent is running in, not a new one. Walk up
// from its pid: a tmux pane is selected (and attached in a new window when no
// client shows it); a terminal app is brought forward. When neither is found
// it says so instead of opening a stranger.

var terminalApps = map[string]string{
	"ghostty": "Ghostty", "iTerm2": "iTerm", "Terminal": "Terminal", "wezterm-gui": "WezTerm",
	"kitty": "kitty", "alacritty": "Alacritty", "Warp": "Warp", "Superset": "Superset",
	"Cursor": "Cursor", "Code": "Visual Studio Code", "zed": "Zed", "Zed": "Zed", "Supacode": "Supacode",
}

func procParent(pid int) (int, string) {
	out, err := exec.Command("ps", "-o", "ppid=,comm=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return 0, ""
	}
	f := strings.Fields(strings.TrimSpace(string(out)))
	if len(f) < 2 {
		return 0, ""
	}
	pp, _ := strconv.Atoi(f[0])
	return pp, filepath.Base(strings.Join(f[1:], " "))
}

// ancestors lists pid and its parents, with their command names.
func ancestors(pid int) ([]int, []string) {
	var pids []int
	var names []string
	for i := 0; pid > 1 && i < 40; i++ {
		pp, name := procParent(pid)
		if name == "" {
			break
		}
		pids, names = append(pids, pid), append(names, name)
		pid = pp
	}
	return pids, names
}

var safeName = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

type goneTo struct{ msg string }

func goToCmd(s Seat) tea.Cmd {
	return func() tea.Msg { return goneTo{goTo(s)} }
}

// goTo brings the agent's terminal forward and says what it did.
func goTo(s Seat) string {
	if s.Pid <= 0 {
		return "✗ no pid for this agent, so its terminal can't be found · e opens its folder"
	}
	pids, names := ancestors(s.Pid)
	if len(pids) == 0 {
		return "✗ its process is gone · e opens its folder"
	}
	for i, n := range names {
		if n == "tmux" || strings.HasPrefix(n, "tmux:") {
			if i == 0 {
				break
			}
			return goToTmux(pids[i-1])
		}
		if app, ok := terminalApps[n]; ok {
			_ = exec.Command("open", "-a", app).Start()
			return "✓ brought " + app + " forward; find the tab for " + clean(s.Addr)
		}
	}
	return "✗ can't find the terminal running it (its parent process left) · e opens its folder"
}

// goToTmux selects the pane whose shell is pid, then shows it: in a client
// already attached, else in a new terminal window.
func goToTmux(panePid int) string {
	out, err := exec.Command("tmux", "list-panes", "-a", "-F", "#{pane_pid} #{session_name}:#{window_index}.#{pane_index}").Output()
	if err != nil {
		return "✗ tmux didn't answer: " + err.Error()
	}
	target := ""
	for _, l := range strings.Split(string(out), "\n") {
		f := strings.Fields(l)
		if len(f) == 2 && f[0] == strconv.Itoa(panePid) {
			target = f[1]
		}
	}
	if target == "" {
		return "✗ found tmux, but not its pane"
	}
	session := strings.SplitN(target, ":", 2)[0]
	if !safeName.MatchString(session) {
		return "✗ tmux session " + clean(session) + ": attach it yourself"
	}
	_ = exec.Command("tmux", "select-window", "-t", target).Run()
	_ = exec.Command("tmux", "select-pane", "-t", target).Run()
	clients, _ := exec.Command("tmux", "list-clients", "-F", "#{client_tty} #{client_pid}").Output()
	if c := strings.Fields(strings.TrimSpace(string(clients))); len(c) >= 2 {
		_ = exec.Command("tmux", "switch-client", "-c", c[0], "-t", target).Run()
		cp, _ := strconv.Atoi(c[1])
		_, names := ancestors(cp)
		for _, n := range names {
			if app, ok := terminalApps[n]; ok {
				_ = exec.Command("open", "-a", app).Start()
				return "✓ switched tmux to " + target + " in " + app
			}
		}
		return "✓ switched tmux to " + target
	}
	if appInstalled("Ghostty") {
		if err := exec.Command("open", "-na", "Ghostty", "--args", "-e", "tmux", "attach", "-t", session).Start(); err == nil {
			return "✓ opened Ghostty attached to tmux " + target
		}
	}
	script := `tell application "Terminal" to do script "tmux attach -t ` + session + `"`
	if err := exec.Command("osascript", "-e", script, "-e", `tell application "Terminal" to activate`).Start(); err != nil {
		return "✗ couldn't open a terminal: run tmux attach -t " + session
	}
	return "✓ opened Terminal attached to tmux " + target
}
