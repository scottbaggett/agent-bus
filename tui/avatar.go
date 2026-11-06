package main

import (
	"crypto/sha1"
	"fmt"
	"strconv"
	"strings"
	"sync"
)

// Every agent gets a little pixel robot, built from its address so the same
// agent always looks the same. The hash picks the body color, head, visor,
// eyes, antenna, mouth, body and feet; the tool colors the antenna and feet.
// Sprites are 10x10 pixels, stretched to 10x14 when drawn (terminal cells
// make half-block pixels wider than tall), in half blocks: 10 columns, 7 rows.

const (
	spriteW = 10
	spriteH = 10
)

// Tool accents: the same colors agent-bus uses for each tool.
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

var bodyColors = []string{
	"#4F8EF7", "#3BB273", "#E4572E", "#F2A541", "#C04CFD", "#FF6FB5", "#2EC4B6", "#8D6E63",
	"#5C6BC0", "#9CCC65", "#EF5350", "#26A69A", "#FFCA28", "#7E57C2", "#78909C", "#EC407A",
}

var eyeColors = []string{"#7CFFB2", "#6FE3FF", "#FF6B6B", "#FFD166", "#FFFFFF", "#FF8AD8", "#B794FF", "#C6FF6B"}

// Parts, as the left half (columns 1-4; column 0 is room for the outline).
// B body, V visor, E eye, A accent, D detail, . empty.
var (
	antennas = [][]string{
		{"....", "...."},
		{"...A", "...B"}, // one stalk in the middle
		{"..A.", "..B."}, // two stalks
		{".A..", ".B.."}, // wide horns
		{"....", "...A"}, // a light on top
	}
	heads = [][]string{
		{"BBBB", "BBBB", "BBBB", "BBBB"}, // boxy
		{".BBB", "BBBB", "BBBB", ".BBB"}, // round
		{"..BB", ".BBB", "BBBB", "BBBB"}, // dome
		{".BBB", "BBBB", "BBBB", "BBBB"}, // bell
	}
	visors = [][]string{
		{"....", ".VVV", ".VEV", "...."}, // wide visor
		{"....", "....", "VVEV", "...."}, // slit
		{"....", ".VV.", ".EV.", "...."}, // goggles
		{"....", "..VV", "..VE", "...."}, // one big eye
		{"....", ".EE.", "....", "...."}, // bare eyes
	}
	bodies = [][]string{
		{".BBB", "ABBB"}, // arms out
		{"BBBB", ".BBB"},
		{"..BB", ".BBA"}, // slim, with a chest light
		{".BBB", ".BAB"}, // belt buckle
	}
	feet = []string{"..A.", ".A..", ".AA.", ".AAA"}
)

type rgb struct{ r, g, b int }

func hexRGB(h string) rgb {
	h = strings.TrimPrefix(h, "#")
	v, _ := strconv.ParseUint(h, 16, 32)
	return rgb{int(v >> 16 & 0xff), int(v >> 8 & 0xff), int(v & 0xff)}
}

func (c rgb) mix(o rgb, t float64) rgb {
	f := func(a, b int) int { return int(float64(a)*(1-t) + float64(b)*t + 0.5) }
	return rgb{f(c.r, o.r), f(c.g, o.g), f(c.b, o.b)}
}

var (
	black = rgb{12, 14, 20}
	white = rgb{255, 255, 255}
	gray  = rgb{88, 88, 92}
)

// sprite is the 10x10 pixel grid; nil means empty.
func sprite(addr, tool string) [spriteH][spriteW]*rgb {
	h := sha1.Sum([]byte(addr))
	pick := func(i, n int) int { return int(h[i]) % n }
	ant, head, vis, body, foot := antennas[pick(0, len(antennas))], heads[pick(1, len(heads))],
		visors[pick(2, len(visors))], bodies[pick(4, len(bodies))], feet[pick(5, len(feet))]
	bodyC := hexRGB(bodyColors[pick(8, len(bodyColors))])
	eyeC := hexRGB(eyeColors[pick(9, len(eyeColors))])
	accent := hexRGB(avatarColor(tool))

	// Left half, rows 1-8; mirrored for the right.
	var half [spriteH][5]byte
	put := func(row int, s string) {
		for i := 0; i < 4 && i < len(s); i++ {
			if s[i] != '.' {
				half[row][i+1] = s[i]
			}
		}
	}
	put(1, ant[0])
	put(2, ant[1])
	for i, r := range head {
		put(2+i, r)
	}
	// Visor, eyes and mouth paint over the head only where it is solid.
	over := func(row int, s string) {
		for i := 0; i < 4 && i < len(s); i++ {
			if s[i] != '.' && half[row][i+1] != 0 {
				half[row][i+1] = s[i]
			}
		}
	}
	for i := range vis {
		over(2+i, vis[i])
	}
	put(6, body[0])
	put(7, body[1])
	put(8, foot)

	visorC := rgb{24, 30, 44}
	var px [spriteH][spriteW]*rgb
	set := func(y, x int, c rgb) { c2 := c; px[y][x] = &c2 }
	for y := 0; y < spriteH; y++ {
		for x := 1; x < 5; x++ {
			k := half[y][x]
			if k == 0 {
				continue
			}
			for _, side := range []int{x, spriteW - 1 - x} {
				c := bodyC
				switch k {
				case 'V':
					c = visorC
				case 'E':
					c = eyeC
				case 'A':
					c = accent
				case 'D':
					c = bodyC.mix(black, 0.5)
				case 'B':
					// Flat: at this size, shading reads as noise.
				}
				set(y, side, c)
			}
		}
	}
	return px
}

// stretch repeats the visor, chest and leg rows so the robot stands taller.
var stretch = [stretchH]int{0, 1, 2, 2, 3, 3, 4, 4, 5, 6, 6, 7, 8, 9}

const stretchH = 14

var spriteCache sync.Map

// avatarArt renders the sprite as 5 lines of half blocks in truecolor; dim
// greys it out for idle agents.
func avatarArt(addr, tool string, dim bool) string {
	key := fmt.Sprintf("%s|%s|%v", addr, tool, dim)
	if v, ok := spriteCache.Load(key); ok {
		return v.(string)
	}
	raw := sprite(addr, tool)
	var px [stretchH][spriteW]*rgb
	for y, src := range stretch {
		px[y] = raw[src]
	}
	col := func(c *rgb) rgb {
		if dim {
			return c.mix(gray, 0.75)
		}
		return *c
	}
	var b strings.Builder
	for y := 0; y+1 < len(px); y += 2 {
		for x := 0; x < spriteW; x++ {
			t, u := px[y][x], px[y+1][x]
			switch {
			case t == nil && u == nil:
				b.WriteByte(' ')
			case u == nil:
				c := col(t)
				fmt.Fprintf(&b, "\x1b[38;2;%d;%d;%dm▀\x1b[0m", c.r, c.g, c.b)
			case t == nil:
				c := col(u)
				fmt.Fprintf(&b, "\x1b[38;2;%d;%d;%dm▄\x1b[0m", c.r, c.g, c.b)
			default:
				c, d := col(t), col(u)
				fmt.Fprintf(&b, "\x1b[38;2;%d;%d;%d;48;2;%d;%d;%dm▀\x1b[0m", c.r, c.g, c.b, d.r, d.g, d.b)
			}
		}
		if y+3 < len(px) {
			b.WriteByte('\n')
		}
	}
	s := b.String()
	spriteCache.Store(key, s)
	return s
}

func toolOf(s Seat) string {
	if s.Tool != "" {
		return s.Tool
	}
	return strings.SplitN(s.Addr, "/", 2)[0]
}

// avatar is the seat's robot, seven lines tall and ten wide.
func avatar(s Seat) string { return avatarArt(s.Addr, toolOf(s), false) }
