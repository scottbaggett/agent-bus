package main

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// What each agent says it's doing: the title of its own session, read
// (read-only) from where each tool keeps it.
//   claude:   $CLAUDE_CONFIG_DIR or ~/.claude: projects/*/<session>.jsonl  (custom-title, ai-title)
//   opencode: ~/.local/share/opencode/opencode.db   (session_v2.title)
//   codex:    ~/.codex/session_index.jsonl          (thread_name)

type titlesMsg map[string]string // addr -> title

func loadTitlesCmd(seats []Seat) tea.Cmd {
	cp := append([]Seat(nil), seats...)
	return func() tea.Msg { return titlesMsg(loadTitles(cp)) }
}

func loadTitles(seats []Seat) map[string]string {
	out := map[string]string{}
	var oc []Seat
	var cx []Seat
	for _, s := range seats {
		if s.Session == "" {
			continue
		}
		switch s.Tool {
		case "claude":
			if t := claudeTitle(s.Session); t != "" {
				out[s.Addr] = t
			}
		case "opencode":
			oc = append(oc, s)
		case "codex":
			cx = append(cx, s)
		}
	}
	for k, v := range opencodeTitles(oc) {
		out[k] = v
	}
	for k, v := range codexTitles(cx) {
		out[k] = v
	}
	return out
}

type fileKey struct {
	size int64
	mod  time.Time
}

var claudeCache sync.Map // path -> struct{k fileKey; t string}

type cachedTitle struct {
	k fileKey
	t string
}

// Where Claude Code keeps its sessions: CLAUDE_CONFIG_DIR when set, and
// ~/.claude, since seats on one bus may run under either.
func claudeDirs() []string {
	dirs := []string{}
	if d := strings.TrimRight(os.Getenv("CLAUDE_CONFIG_DIR"), "/"); d != "" {
		dirs = append(dirs, d)
	}
	if def := filepath.Join(homeDir(), ".claude"); len(dirs) == 0 || dirs[0] != def {
		dirs = append(dirs, def)
	}
	return dirs
}

func claudeTitle(session string) string {
	if strings.ContainsAny(session, "/\\*?[") {
		return ""
	}
	var matches []string
	for _, d := range claudeDirs() {
		m, _ := filepath.Glob(filepath.Join(d, "projects", "*", session+".jsonl"))
		matches = append(matches, m...)
	}
	if len(matches) == 0 {
		return ""
	}
	p := matches[0]
	fi, err := os.Stat(p)
	if err != nil {
		return ""
	}
	k := fileKey{fi.Size(), fi.ModTime()}
	if v, ok := claudeCache.Load(p); ok && v.(cachedTitle).k == k {
		return v.(cachedTitle).t
	}
	f, err := os.Open(p)
	if err != nil {
		return ""
	}
	defer f.Close()
	var custom, ai string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		b := sc.Bytes()
		if len(b) > 400 || !strings.Contains(string(b), "-title\"") {
			continue
		}
		var r struct {
			Type        string `json:"type"`
			CustomTitle string `json:"customTitle"`
			AITitle     string `json:"aiTitle"`
		}
		if json.Unmarshal(b, &r) != nil {
			continue
		}
		switch r.Type {
		case "custom-title":
			custom = r.CustomTitle
		case "ai-title":
			ai = r.AITitle
		}
	}
	t := custom
	if t == "" {
		t = ai
	}
	t = clean(strings.TrimSpace(t))
	claudeCache.Store(p, cachedTitle{k, t})
	return t
}

func opencodeTitles(seats []Seat) map[string]string {
	out := map[string]string{}
	if len(seats) == 0 {
		return out
	}
	db := filepath.Join(homeDir(), ".local", "share", "opencode", "opencode.db")
	if _, err := os.Stat(db); err != nil {
		return out
	}
	var ids []string
	byID := map[string]string{}
	for _, s := range seats {
		if strings.Trim(s.Session, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_") != "" {
			continue // only plain ids go into the query
		}
		ids = append(ids, "'"+s.Session+"'")
		byID[s.Session] = s.Addr
	}
	if len(ids) == 0 {
		return out
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	q := "select id, title from session_v2 where id in (" + strings.Join(ids, ",") + ");"
	res, err := exec.CommandContext(ctx, "sqlite3", "-readonly", "-separator", "\t", db, q).Output()
	if err != nil {
		return out
	}
	for _, l := range strings.Split(string(res), "\n") {
		id, title, ok := strings.Cut(l, "\t")
		if ok && byID[id] != "" && strings.TrimSpace(title) != "" {
			out[byID[id]] = clean(strings.TrimSpace(title))
		}
	}
	return out
}

func codexTitles(seats []Seat) map[string]string {
	out := map[string]string{}
	if len(seats) == 0 {
		return out
	}
	byID := map[string]string{}
	for _, s := range seats {
		byID[s.Session] = s.Addr
	}
	f, err := os.Open(filepath.Join(homeDir(), ".codex", "session_index.jsonl"))
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 16<<20)
	for sc.Scan() {
		var r struct {
			ID   string `json:"id"`
			Name string `json:"thread_name"`
		}
		if json.Unmarshal(sc.Bytes(), &r) == nil && byID[r.ID] != "" && r.Name != "" {
			out[byID[r.ID]] = clean(strings.TrimSpace(r.Name))
		}
	}
	return out
}
