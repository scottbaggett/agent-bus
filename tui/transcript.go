package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

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

func claudeTranscript(session string) string {
	if session == "" || strings.ContainsAny(session, "/\\*?[") {
		return ""
	}
	matches, _ := filepath.Glob(filepath.Join(homeDir(), ".claude", "projects", "*", session+".jsonl"))
	if len(matches) == 0 {
		return ""
	}
	return matches[0]
}

// transcriptStamp changes when the agent's session log does.
func transcriptStamp(s Seat) string {
	if s.Tool != "claude" {
		return ""
	}
	p := claudeTranscript(s.Session)
	fi, err := os.Stat(p)
	if p == "" || err != nil {
		return ""
	}
	return fmt.Sprintf("|%d|%d", fi.Size(), fi.ModTime().UnixNano())
}

// claudeLog is the recent part of an agent's own session as log entries:
// your prompts, its replies, and one line per tool it ran.
func claudeLog(session string) []chatMsg {
	p := claudeTranscript(session)
	if p == "" {
		return nil
	}
	f, err := os.Open(p)
	if err != nil {
		return nil
	}
	defer f.Close()
	const tail = 2 << 20
	if fi, err := f.Stat(); err == nil && fi.Size() > tail {
		_, _ = f.Seek(fi.Size()-tail, io.SeekStart)
	}
	b, _ := io.ReadAll(f)
	var out []chatMsg
	for _, l := range strings.Split(string(b), "\n") {
		if !strings.Contains(l, `"type":"user"`) && !strings.Contains(l, `"type":"assistant"`) {
			continue
		}
		var r struct {
			Type      string `json:"type"`
			Sidechain bool   `json:"isSidechain"`
			Meta      bool   `json:"isMeta"`
			Timestamp string `json:"timestamp"`
			UUID      string `json:"uuid"`
			Message   struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal([]byte(l), &r) != nil || r.Sidechain || r.Meta {
			continue
		}
		t, err := time.Parse(time.RFC3339Nano, r.Timestamp)
		if err != nil {
			continue
		}
		at := t.Unix()
		var str string
		var parts []struct {
			Type  string          `json:"type"`
			Text  string          `json:"text"`
			Name  string          `json:"name"`
			Input json.RawMessage `json:"input"`
		}
		if json.Unmarshal(r.Message.Content, &str) != nil {
			_ = json.Unmarshal(r.Message.Content, &parts)
		}
		switch r.Type {
		case "user":
			text := str
			for _, p := range parts {
				if p.Type == "text" {
					text += p.Text
				}
			}
			text = strings.TrimSpace(text)
			// Skip what the harness injects rather than what you typed.
			if text == "" || strings.HasPrefix(text, "<") || strings.HasPrefix(text, "[Request interrupted") ||
				strings.HasPrefix(text, "Caveat:") {
				continue
			}
			out = append(out, chatMsg{ID: r.UUID, Epoch: at, Kind: "asked", Body: text, Mine: true})
		case "assistant":
			for _, p := range parts {
				switch p.Type {
				case "text":
					if strings.TrimSpace(p.Text) != "" {
						out = append(out, chatMsg{ID: r.UUID, Epoch: at, Kind: "said", Body: p.Text})
					}
				case "tool_use":
					out = append(out, chatMsg{ID: r.UUID, Epoch: at, Kind: "tool", Subject: p.Name + ": " + toolGist(p.Input)})
				}
			}
		}
	}
	if len(out) > 300 {
		out = out[len(out)-300:]
	}
	return out
}
