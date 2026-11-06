package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Snapshot is the subset of `agent-bus snapshot` the TUI shows. The CLI owns
// the bus; the TUI only reads this and runs the CLI for actions.
type Snapshot struct {
	Now       int64   `json:"now"`
	Bus       string  `json:"bus"`
	Seats     []Seat  `json:"seats"`
	Open      []Item  `json:"open"`
	Attention []Att   `json:"attention"`
	Recent    []Event `json:"recent"`
	Peers     []Peer  `json:"peers"`
}

type Seat struct {
	Addr    string `json:"addr"`
	Tool    string `json:"tool"`
	Repo    string `json:"repo"`
	Branch  string `json:"branch"`
	Lane    string `json:"lane"`
	Cwd     string `json:"cwd"`
	Session string `json:"session"`
	Focus   string `json:"focus"`
	Epoch   int64  `json:"epoch"`
	Avatar  struct {
		Color string `json:"color"`
	} `json:"avatar"`
}

type Item struct {
	ID      string `json:"id"`
	Epoch   int64  `json:"epoch"`
	From    string `json:"from"`
	To      string `json:"to"`
	State   string `json:"state"`
	Subject string `json:"subject"`
	Repo    string `json:"repo"`
	Lane    string `json:"lane"`
	Owner   string `json:"owner"`
	Gone    bool   `json:"gone"`
	Stale   bool   `json:"stale"`
	Unread  bool   `json:"unread"`
}

type Att struct {
	Kind  string `json:"kind"`
	ID    string `json:"id"`
	Epoch int64  `json:"epoch"`
	From  string `json:"from"`
	Repo  string `json:"repo"`
	Lane  string `json:"lane"`
	Text  string `json:"text"`
	Fix   string `json:"fix"`
}

type Event struct {
	Kind      string `json:"kind"`
	ID        string `json:"id"`
	Epoch     int64  `json:"epoch"`
	From      string `json:"from"`
	To        string `json:"to"`
	State     string `json:"state"`
	Subject   string `json:"subject"`
	Close     string `json:"close"`
	Reason    string `json:"reason"`
	Status    string `json:"status"`
	Transport string `json:"transport"`
}

type Peer struct {
	Host   string `json:"host"`
	Name   string `json:"name"`
	Synced int64  `json:"synced"`
	Seats  []Seat `json:"seats"`
}

// cli is the agent-bus the wrapper ran us from (AGENT_BUS_CLI), else PATH.
func cli() string {
	if c := os.Getenv("AGENT_BUS_CLI"); c != "" {
		return c
	}
	return "agent-bus"
}

// run invokes the CLI as the human (@lead): the person at this terminal.
func run(args ...string) (string, error) {
	cmd := exec.Command(cli(), args...)
	cmd.Env = append(os.Environ(), "AGENT_BUS_TOOL=lead")
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func loadSnapshot() (*Snapshot, error) {
	cmd := exec.Command(cli(), "snapshot")
	cmd.Env = append(os.Environ(), "AGENT_BUS_TOOL=lead")
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	var s Snapshot
	if err := json.Unmarshal(out, &s); err != nil {
		return nil, err
	}
	return &s, nil
}

// ledgerStamp changes whenever the ledger is appended to.
func ledgerStamp(bus string) string {
	if bus == "" {
		return ""
	}
	fi, err := os.Stat(bus + "/ledger.jsonl")
	if err != nil {
		return ""
	}
	return fi.ModTime().String() + "/" + fmtInt(fi.Size())
}

func fmtInt(n int64) string { return strconv.FormatInt(n, 10) }

// ago renders an epoch as a short age: 12s, 4m, 3h, 2d.
func ago(now, epoch int64) string {
	if epoch <= 0 {
		return "-"
	}
	if now <= 0 {
		now = time.Now().Unix()
	}
	d := now - epoch
	switch {
	case d < 0:
		return "now"
	case d < 60:
		return fmtInt(d) + "s"
	case d < 3600:
		return fmtInt(d/60) + "m"
	case d < 86400:
		return fmtInt(d/3600) + "h"
	default:
		return fmtInt(d/86400) + "d"
	}
}

// clean strips control characters: packets come from other agents, and a
// subject must never be able to move the cursor or recolor the screen.
func clean(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r == '\n' || r == '\t':
			b.WriteRune(' ')
		case r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0):
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

func getenv(k string) string { return os.Getenv(k) }

func homeDir() string { h, _ := os.UserHomeDir(); return strings.TrimRight(h, "/") }
