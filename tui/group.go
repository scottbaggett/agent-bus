package main

import (
	"os"
	"strings"
)

// g cycles how the grid groups agents: by lane, by tool, by repo, by Mac, or
// not at all.

type groupBy int

const (
	byLane groupBy = iota
	byTool
	byRepo
	byMac
	byNone
	groupModes
)

func (g groupBy) String() string {
	return [...]string{"lane", "tool", "repo", "Mac", "nothing"}[g]
}

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
		return t.seat.Repo
	case byMac:
		if t.peer != "" {
			return t.peer
		}
		return localHost()
	case byNone:
		return ""
	}
	return t.seat.Lane
}

func (g groupBy) emptyLabel() string {
	switch g {
	case byRepo:
		return "no repo"
	case byNone:
		return "agents"
	}
	return "no lane"
}
