package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// g cycles how the grid groups agents: by repo (the default: every agent has
// one), lane, tool, Mac, or not at all. The choice is remembered.

type groupBy int

const (
	byRepo groupBy = iota
	byStage
	byLane
	byTool
	byMac
	byNone
	groupModes
)

func (g groupBy) String() string {
	return [...]string{"repo", "stage", "lane", "tool", "Mac", "nothing"}[g]
}

// prefsFile keeps the TUI's own settings, apart from the bus.
func prefsFile() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "agent-bus", "tui.json")
}

type prefs struct {
	GroupBy     string `json:"group_by,omitempty"`
	Welcomed    bool   `json:"welcomed,omitempty"`
	SeenVersion string `json:"seen_version,omitempty"`
}

func loadPrefs() (prefs, bool) {
	var p prefs
	b, err := os.ReadFile(prefsFile())
	if err != nil {
		return p, false
	}
	return p, json.Unmarshal(b, &p) == nil
}

func savePrefs(change func(*prefs)) {
	f := prefsFile()
	if f == "" || os.MkdirAll(filepath.Dir(f), 0o755) != nil {
		return
	}
	p, _ := loadPrefs()
	change(&p)
	b, _ := json.Marshal(p)
	_ = os.WriteFile(f, b, 0o644)
}

func loadGroupBy() groupBy {
	p, _ := loadPrefs()
	for g := groupBy(0); g < groupModes; g++ {
		if g.String() == p.GroupBy {
			return g
		}
	}
	return byRepo
}

func saveGroupBy(g groupBy) { savePrefs(func(p *prefs) { p.GroupBy = g.String() }) }

func toolLabel(t string) string {
	switch t {
	case "claude":
		return "Claude"
	case "codex":
		return "Codex"
	case "opencode":
		return "OpenCode"
	case "grok":
		return "Grok"
	}
	return t
}

func localHost() string {
	h, _ := os.Hostname()
	return strings.TrimSuffix(strings.SplitN(h, ".", 2)[0], ".local")
}

// groupKey is the group a tile belongs to; "" sorts last and gets emptyLabel.
func (g groupBy) key(t tile) string {
	switch g {
	case byTool:
		return toolLabel(toolOf(t.seat))
	case byRepo:
		if r := t.seat.Repo; r != "" && r != "-" {
			return r
		}
		// Not a git checkout: its folder's name is the best guess at the project.
		if c := strings.TrimRight(t.seat.Cwd, "/"); c != "" && c != homeDir() {
			return filepath.Base(c)
		}
		return ""
	case byMac:
		if t.peer != "" {
			return t.peer
		}
		return localHost()
	case byNone:
		return ""
	case byStage:
		return stageLabel(t.seat.Stage)
	}
	return t.seat.Lane
}

func (g groupBy) emptyLabel() string {
	switch g {
	case byRepo:
		return "no repo"
	case byNone:
		return "agents"
	case byStage:
		return "no stage set"
	}
	return "no lane"
}

func stageLabel(s string) string {
	switch s {
	case "in-progress":
		return "In progress"
	case "review":
		return "Ready for review"
	case "blocked":
		return "Blocked"
	case "parked":
		return "Parked"
	case "done":
		return "Done"
	}
	return ""
}
