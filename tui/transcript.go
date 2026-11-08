package main

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"

	tea "github.com/charmbracelet/bubbletea"
)

// What an agent is doing right now, read (read-only) from the tail of its own
// session transcript: the last thing you asked it, and its latest move, either
// a tool it is running or what it last said. Claude Code only for now.

type nowInfo struct {
	Asked string // your last prompt
	Doing string // "Bash: go test ./..." or its latest words
}

var nowCache sync.Map // path -> struct{k fileKey; n nowInfo}

type cachedNow struct {
	k fileKey
	n nowInfo
}

type nowAllMsg map[string]nowInfo

// loadNowCmd reads every local Claude agent's transcript tail (cached by size
// and time, so an unchanged one costs a stat).
func loadNowCmd(seats []Seat) tea.Cmd {
	cp := append([]Seat(nil), seats...)
	return func() tea.Msg {
		out := nowAllMsg{}
		for _, s := range cp {
			if s.Tool != "claude" || s.Session == "" || strings.ContainsAny(s.Session, "/\\*?[") {
				continue
			}
			if n := claudeNow(s.Session); n != (nowInfo{}) {
				out[s.Addr] = n
			}
		}
		return out
	}
}

func claudeNow(session string) nowInfo {
	matches, _ := filepath.Glob(filepath.Join(homeDir(), ".claude", "projects", "*", session+".jsonl"))
	if len(matches) == 0 {
		return nowInfo{}
	}
	p := matches[0]
	fi, err := os.Stat(p)
	if err != nil {
		return nowInfo{}
	}
	k := fileKey{fi.Size(), fi.ModTime()}
	if v, ok := nowCache.Load(p); ok && v.(cachedNow).k == k {
		return v.(cachedNow).n
	}
	f, err := os.Open(p)
	if err != nil {
		return nowInfo{}
	}
	defer f.Close()
	const tail = 512 << 10
	if fi.Size() > tail {
		_, _ = f.Seek(fi.Size()-tail, io.SeekStart)
	}
	b, _ := io.ReadAll(f)
	lines := strings.Split(string(b), "\n")
	var n nowInfo
	for i := len(lines) - 1; i >= 0 && (n.Asked == "" || n.Doing == ""); i-- {
		l := lines[i]
		switch {
		case n.Asked == "" && strings.Contains(l, `"type":"last-prompt"`):
			var r struct {
				LastPrompt string `json:"lastPrompt"`
			}
			if json.Unmarshal([]byte(l), &r) == nil {
				n.Asked = oneLine(r.LastPrompt)
			}
		case n.Doing == "" && strings.Contains(l, `"type":"assistant"`):
			var r struct {
				Type    string `json:"type"`
				Message struct {
					Content []struct {
						Type  string          `json:"type"`
						Text  string          `json:"text"`
						Name  string          `json:"name"`
						Input json.RawMessage `json:"input"`
					} `json:"content"`
				} `json:"message"`
			}
			if json.Unmarshal([]byte(l), &r) != nil || r.Type != "assistant" {
				continue
			}
			for _, c := range r.Message.Content {
				switch c.Type {
				case "tool_use":
					n.Doing = c.Name + ": " + toolGist(c.Input)
				case "text":
					if t := oneLine(c.Text); t != "" {
						n.Doing = t
					}
				}
			}
		}
	}
	nowCache.Store(p, cachedNow{k, n})
	return n
}

// toolGist is the readable part of a tool call: its description, command,
// file or pattern.
func toolGist(raw json.RawMessage) string {
	var in map[string]any
	if json.Unmarshal(raw, &in) != nil {
		return ""
	}
	for _, k := range []string{"description", "command", "file_path", "pattern", "url", "prompt", "query"} {
		if v, ok := in[k].(string); ok && strings.TrimSpace(v) != "" {
			if k == "file_path" {
				v = filepath.Base(v)
			}
			return oneLine(v)
		}
	}
	return ""
}

func oneLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, "\n"); i >= 0 {
		s = s[:i]
	}
	s = clean(strings.TrimLeft(s, "# "))
	if r := []rune(s); len(r) > 200 {
		s = string(r[:200]) + "…"
	}
	return s
}
