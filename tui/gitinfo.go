package main

import (
	"context"
	"encoding/json"
	"os/exec"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// The code side of an agent: its branch against upstream, uncommitted files,
// last commit, and the pull request (GitHub, via gh) or merge request
// (GitLab, via glab) for its branch. Read when its panel
// opens, and at most once a minute.

type gitInfo struct {
	At                   time.Time
	Branch               string
	Ahead, Behind, Dirty int
	Last                 string // short sha, subject, age
	PR                   *prInfo
	Err                  string
}

type prInfo struct {
	Kind     string // "PR" or "MR"
	Pipeline string // GitLab: the head pipeline's status
	Number   int    `json:"number"`
	State    string `json:"state"`
	URL      string `json:"url"`
	Title    string `json:"title"`
	Review   string `json:"reviewDecision"`
	Checks   []struct {
		Conclusion string `json:"conclusion"`
		State      string `json:"state"`
	} `json:"statusCheckRollup"`
}

type gitMsg struct {
	addr string
	info gitInfo
}

func runIn(dir string, timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	out, err := cmd.Output()
	return strings.TrimSpace(string(out)), err
}

func loadGitCmd(addr, dir string) tea.Cmd {
	return func() tea.Msg { return gitMsg{addr, readGit(dir)} }
}

func readGit(dir string) gitInfo {
	g := gitInfo{At: time.Now()}
	if dir == "" {
		g.Err = "no folder"
		return g
	}
	st, err := runIn(dir, 3*time.Second, "git", "status", "--porcelain=2", "--branch")
	if err != nil {
		g.Err = "not a git folder"
		return g
	}
	for _, l := range strings.Split(st, "\n") {
		switch {
		case strings.HasPrefix(l, "# branch.head "):
			g.Branch = strings.TrimPrefix(l, "# branch.head ")
		case strings.HasPrefix(l, "# branch.ab "):
			f := strings.Fields(strings.TrimPrefix(l, "# branch.ab "))
			if len(f) == 2 {
				g.Ahead, _ = strconv.Atoi(strings.TrimPrefix(f[0], "+"))
				g.Behind, _ = strconv.Atoi(strings.TrimPrefix(f[1], "-"))
			}
		case l != "" && l[0] != '#':
			g.Dirty++
		}
	}
	g.Last, _ = runIn(dir, 3*time.Second, "git", "log", "-1", "--format=%h %s · %cr")
	if g.Branch != "" && g.Branch != "main" && g.Branch != "master" && g.Branch != "develop" && !strings.HasPrefix(g.Branch, "(") {
		origin, _ := runIn(dir, 2*time.Second, "git", "remote", "get-url", "origin")
		if strings.Contains(strings.ToLower(origin), "gitlab") {
			g.PR = readMR(dir)
		} else {
			g.PR = readPR(dir)
		}
	}
	return g
}

func readPR(dir string) *prInfo {
	if _, err := exec.LookPath("gh"); err != nil {
		return nil
	}
	out, err := runIn(dir, 8*time.Second, "gh", "pr", "view", "--json", "number,state,url,title,reviewDecision,statusCheckRollup")
	if err != nil {
		return nil
	}
	var p prInfo
	if json.Unmarshal([]byte(out), &p) != nil || p.Number == 0 {
		return nil
	}
	p.Kind = "PR"
	return &p
}

func readMR(dir string) *prInfo {
	if _, err := exec.LookPath("glab"); err != nil {
		return nil
	}
	out, err := runIn(dir, 10*time.Second, "glab", "mr", "view", "-F", "json")
	if err != nil {
		return nil
	}
	var mr struct {
		IID    int    `json:"iid"`
		State  string `json:"state"`
		URL    string `json:"web_url"`
		Title  string `json:"title"`
		Draft  bool   `json:"draft"`
		Status string `json:"detailed_merge_status"`
		Head   *struct {
			Status string `json:"status"`
		} `json:"head_pipeline"`
		Pipe *struct {
			Status string `json:"status"`
		} `json:"pipeline"`
	}
	if json.Unmarshal([]byte(out), &mr) != nil || mr.IID == 0 {
		return nil
	}
	p := &prInfo{Kind: "MR", Number: mr.IID, State: mr.State, URL: mr.URL, Title: mr.Title, Review: mr.Status}
	if mr.Draft {
		p.State = "draft"
	}
	switch {
	case mr.Head != nil:
		p.Pipeline = mr.Head.Status
	case mr.Pipe != nil:
		p.Pipeline = mr.Pipe.Status
	}
	return p
}

// ref is how the request is written: #812 for a PR, !3886 for an MR.
func (p prInfo) ref() string {
	if p.Kind == "MR" {
		return "!" + strconv.Itoa(p.Number)
	}
	return "#" + strconv.Itoa(p.Number)
}

// checks sums a PR's checks: "✓ checks", "✗ 2 failing", "… 3 running".
func (p prInfo) checks() (string, string) {
	switch strings.ToLower(p.Pipeline) {
	case "":
	case "success":
		return "✓ pipeline", "good"
	case "failed", "canceled":
		return "✗ pipeline " + strings.ToLower(p.Pipeline), "bad"
	default:
		return "… pipeline " + strings.ToLower(strings.ReplaceAll(p.Pipeline, "_", " ")), "warn"
	}
	fail, run := 0, 0
	for _, c := range p.Checks {
		switch strings.ToUpper(c.Conclusion + c.State) {
		case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED":
			fail++
		case "", "PENDING", "IN_PROGRESS", "QUEUED", "EXPECTED":
			run++
		}
	}
	switch {
	case len(p.Checks) == 0:
		return "", "dim"
	case fail > 0:
		return "✗ " + strconv.Itoa(fail) + " failing", "bad"
	case run > 0:
		return "… " + strconv.Itoa(run) + " running", "warn"
	}
	return "✓ checks", "good"
}
