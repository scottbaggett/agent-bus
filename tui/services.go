package main

import (
	"bufio"
	"bytes"
	"context"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// A service is a process listening on a TCP port, tied to an agent by its
// working directory: a dev server started inside an agent's worktree counts
// as that agent's.
type service struct {
	PID  int
	Cmd  string
	Port int
	Cwd  string
	Up   []int // its parent pids, nearest first
}

type servicesMsg struct {
	list []service
	err  error
}

func scanServicesCmd() tea.Cmd {
	return func() tea.Msg { l, err := scanServices(); return servicesMsg{l, err} }
}

func lsof(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "lsof", args...).Output()
}

// scanServices lists listening TCP ports with their process and its cwd.
func scanServices() ([]service, error) {
	out, err := lsof("-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn")
	if err != nil && len(out) == 0 {
		// lsof exits 1 when nothing matches.
		return nil, nil
	}
	type key struct{ pid, port int }
	seen := map[key]bool{}
	var list []service
	var pid int
	var cmd string
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		l := sc.Text()
		if l == "" {
			continue
		}
		switch l[0] {
		case 'p':
			pid, _ = strconv.Atoi(l[1:])
		case 'c':
			cmd = l[1:]
		case 'n':
			i := strings.LastIndexByte(l, ':')
			if i < 0 {
				continue
			}
			port, err := strconv.Atoi(l[i+1:])
			if err != nil || seen[key{pid, port}] {
				continue
			}
			seen[key{pid, port}] = true
			list = append(list, service{PID: pid, Cmd: cmd, Port: port})
		}
	}
	if len(list) == 0 {
		return nil, nil
	}
	var pids []string
	done := map[int]bool{}
	for _, s := range list {
		if !done[s.PID] {
			done[s.PID] = true
			pids = append(pids, strconv.Itoa(s.PID))
		}
	}
	cwds := map[int]string{}
	if out, _ := lsof("-a", "-d", "cwd", "-Fpn", "-p", strings.Join(pids, ",")); len(out) > 0 {
		sc := bufio.NewScanner(bytes.NewReader(out))
		for sc.Scan() {
			l := sc.Text()
			if l == "" {
				continue
			}
			switch l[0] {
			case 'p':
				pid, _ = strconv.Atoi(l[1:])
			case 'n':
				cwds[pid] = l[1:]
			}
		}
	}
	parent := map[int]int{}
	if out, err := exec.Command("ps", "-axo", "pid=,ppid=").Output(); err == nil {
		for _, l := range strings.Split(string(out), "\n") {
			f := strings.Fields(l)
			if len(f) == 2 {
				p, _ := strconv.Atoi(f[0])
				pp, _ := strconv.Atoi(f[1])
				parent[p] = pp
			}
		}
	}
	for i := range list {
		list[i].Cwd = cwds[list[i].PID]
		for p, n := parent[list[i].PID], 0; p > 1 && n < 40; p, n = parent[p], n+1 {
			list[i].Up = append(list[i].Up, p)
		}
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Port < list[j].Port })
	return list, nil
}

// servicesFor is what an agent runs: servers its own process started, else
// servers in its folder that no other agent has a closer claim to. A PM in a
// repo's main checkout doesn't get the dev servers of the worktrees inside it.
func (m model) servicesFor(s Seat) []service {
	var out []service
	for _, svc := range m.services {
		if m.ownerOf(svc) == s.Addr {
			out = append(out, svc)
		}
	}
	return out
}

func (m model) ownerOf(svc service) string {
	if m.snap == nil {
		return ""
	}
	for _, s := range m.snap.Seats {
		for _, p := range svc.Up {
			if s.Pid > 1 && p == s.Pid {
				return s.Addr
			}
		}
	}
	best, bestLen := "", 0
	for _, s := range m.snap.Seats {
		root := strings.TrimRight(s.Cwd, "/")
		if root == "" || root == "/" || root == homeDir() {
			continue
		}
		if (svc.Cwd == root || strings.HasPrefix(svc.Cwd, root+"/")) && len(root) > bestLen {
			best, bestLen = s.Addr, len(root)
		}
	}
	if best == "" {
		return ""
	}
	// A server inside a worktree of the folder belongs to that worktree.
	for _, s := range m.snap.Seats {
		if s.Addr == best {
			rel := strings.TrimPrefix(svc.Cwd, strings.TrimRight(s.Cwd, "/"))
			if strings.Contains(rel, "/.claude/worktrees/") || strings.Contains(rel, "/.worktrees/") {
				return ""
			}
		}
	}
	return best
}

func ports(svcs []service) string {
	var p []string
	for _, s := range svcs {
		p = append(p, ":"+strconv.Itoa(s.Port))
	}
	return strings.Join(p, " ")
}

// openEditor opens Zed (or $AGENT_BUS_EDITOR) in a folder, without waiting.
func openEditor(dir string) error {
	if ed := strings.TrimSpace(getenv("AGENT_BUS_EDITOR")); ed != "" {
		f := strings.Fields(ed)
		return exec.Command(f[0], append(f[1:], dir)...).Start()
	}
	if p, err := exec.LookPath("zed"); err == nil {
		return exec.Command(p, dir).Start()
	}
	return exec.Command("open", "-a", "Zed", dir).Start()
}

func openURL(u string) error { return exec.Command("open", u).Start() }
