package main

import (
	"crypto/sha1"
	"encoding/hex"
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// A seat's bot, the same one `agent-bus avatar` draws (bin/agent-bus,
// avatar_bits/avatar_art): the tool sets the head and color, the hash of the
// address the antenna, eyes and legs. Keep the two in step.

func avatarColor(tool string) string {
	switch tool {
	case "claude":
		return "#E0855F"
	case "codex":
		return "#79AEFF"
	case "opencode":
		return "#F2C94C"
	case "grok":
		return "#E8E3D8"
	}
	return "#9A9384"
}

func avatarBits(addr, tool string) []string {
	sum := sha1.Sum([]byte(addr))
	h := hex.EncodeToString(sum[:])
	n := func(i int) int { v, _ := strconv.ParseInt(h[i:i+2], 16, 0); return int(v) }
	t, e, l := n(0)%3, n(2)%3, n(4)%3
	top := [...]string{"........", "...##...", "..#..#.."}[t]
	eyes := [...]string{".##.", "#..#", "...."}[e]
	var head, erow, b1, b2 string
	switch tool {
	case "claude":
		head, erow, b1, b2 = ".######.", ".#"+eyes+"#.", "########", ".######."
	case "codex":
		head, erow, b1, b2 = ".######.", "##"+eyes+"##", ".######.", ".######."
	case "opencode":
		head, erow, b1, b2 = "########", "##"+eyes+"##", "#.####.#", "..####.."
	default:
		head, erow, b1, b2 = ".######.", ".#"+eyes+"#.", ".######.", ".######."
	}
	legs := [...][2]string{{"..#..#..", "..#..#.."}, {".##..##.", ".#....#."}, {"..####..", ".#....#."}}[l]
	return []string{top, head, erow, head, b1, b2, legs[0], legs[1]}
}

// avatarRows renders the 8x8 bitmap as four lines of half blocks.
func avatarRows(addr, tool string) []string {
	bits := avatarBits(addr, tool)
	out := make([]string, 0, 4)
	for i := 0; i < 8; i += 2 {
		var b strings.Builder
		for j := 0; j < 8; j++ {
			a, c := bits[i][j] == '#', bits[i+1][j] == '#'
			switch {
			case a && c:
				b.WriteString("█")
			case a:
				b.WriteString("▀")
			case c:
				b.WriteString("▄")
			default:
				b.WriteString(" ")
			}
		}
		out = append(out, b.String())
	}
	return out
}

func toolOf(s Seat) string {
	if s.Tool != "" {
		return s.Tool
	}
	return strings.SplitN(s.Addr, "/", 2)[0]
}

// avatar is the seat's bot, colored, four lines tall and eight wide.
func avatar(s Seat) string {
	st := lipgloss.NewStyle().Foreground(lipgloss.Color(avatarColor(toolOf(s))))
	return st.Render(strings.Join(avatarRows(s.Addr, toolOf(s)), "\n"))
}
