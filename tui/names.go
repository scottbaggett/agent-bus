package main

import (
	"crypto/sha1"
	"regexp"
	"strings"
)

// Every agent gets a name you can say out loud, made from its address the
// same way its bot is: the same agent is always "Brave Otter".
var nameAdj = []string{
	"Amber", "Brave", "Calm", "Clever", "Cosmic", "Crisp", "Dusty", "Eager", "Fuzzy", "Gentle",
	"Happy", "Jolly", "Keen", "Lucky", "Mellow", "Misty", "Nimble", "Noble", "Plucky", "Quiet",
	"Rapid", "Rusty", "Shiny", "Sly", "Snowy", "Spry", "Sunny", "Swift", "Tidy", "Witty",
	"Zesty", "Bold", "Brisk", "Cheery", "Daring", "Frosty", "Grumpy", "Hasty", "Ionic", "Jazzy",
}

var nameNoun = []string{
	"Otter", "Falcon", "Badger", "Comet", "Pixel", "Quokka", "Raven", "Gecko", "Panda", "Lynx",
	"Heron", "Moose", "Newt", "Koala", "Bison", "Robin", "Walrus", "Yak", "Ferret", "Puffin",
	"Marmot", "Orca", "Tapir", "Wombat", "Beetle", "Cobra", "Dingo", "Egret", "Finch", "Hare",
	"Ibis", "Jackal", "Lemur", "Mantis", "Narwhal", "Ocelot", "Pika", "Quail", "Sloth", "Toucan",
}

func friendlyName(addr string) string {
	h := sha1.Sum([]byte(addr))
	return nameAdj[int(h[6])%len(nameAdj)] + " " + nameNoun[int(h[7])%len(nameNoun)]
}

var ticketRe = regexp.MustCompile(`(?i)\b([a-z]{2,10})-(\d{1,6})\b`)

// workingOn is what an agent is on, in a few words: the ticket its branch
// names, else the branch, else the repo.
func workingOn(s Seat) string {
	b := strings.TrimSpace(s.Branch)
	if m := ticketRe.FindStringSubmatch(b); m != nil {
		return strings.ToUpper(m[1]) + "-" + m[2]
	}
	if s.Lane != "" {
		if m := ticketRe.FindStringSubmatch(s.Lane); m != nil {
			return strings.ToUpper(m[1]) + "-" + m[2]
		}
	}
	switch {
	case b == "" || b == "-" || b == "main" || b == "master" || b == "develop" || strings.HasPrefix(b, "detached"):
		if s.Repo != "" && s.Repo != "-" {
			return s.Repo
		}
		return b
	}
	for _, p := range []string{"feature/", "feat/", "fix/", "chore/", "docs/"} {
		b = strings.TrimPrefix(b, p)
	}
	return b
}
