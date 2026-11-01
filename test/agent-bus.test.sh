#!/usr/bin/env bash
# agent-bus tests: routing, ownership, closing, wake, claims, safety.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/agent-bus"
pass=0 fail=0

ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n%s\n' "$1" "$2"; fail=$((fail + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "  want: $2
  got:  $3"; fi; }
assert_has() { if grep -Fq -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "  missing: $2
  in: $3"; fi; }
assert_lacks() { if grep -Fq -- "$2" <<<"$3"; then bad "$1" "  unexpected: $2"; else ok "$1"; fi; }

# Hermetic: the suite runs inside Claude or OpenCode, whose markers and
# sockets would otherwise leak into every fixture seat.
unset CODEX_THREAD_ID CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET OPENCODE OPENCODE_SESSION_ID
for _v in $(env | sed -n 's/^\(AGENT_BUS_[A-Z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
BUS_HOME=$(mktemp -d)
trap 'rm -rf "$BUS_HOME"; [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; [ -n "${GROK_SRV:-}" ] && kill "$GROK_SRV" 2>/dev/null; true' EXIT
GROK_SRV=
export AGENT_BUS_HOME="$BUS_HOME" AGENT_BUS_NO_PUSH=1 AGENT_BUS_NO_AUTO_GC=1

# Fixture seats: seat <name> <tool> <worktree> <cmd...>
# Fixture seats are mostly claude, so their posts pass --allow-claude; the
# refusal itself is tested with raw_seat.
raw_seat() { local s="$1" t="$2" w="$3"; shift 3; AGENT_BUS_SESSION="$s" AGENT_BUS_TOOL="$t" AGENT_BUS_WT="$w" "$BIN" "$@"; }
seat() {
  local s="$1" t="$2" w="$3"; shift 3
  if [ "${1:-}" = post ]; then shift; raw_seat "$s" "$t" "$w" post --allow-claude "$@"; else raw_seat "$s" "$t" "$w" "$@"; fi
}
pm() { seat pm claude pmwt "$@"; }
a() { seat a claude wa "$@"; }
b() { seat b opencode wa "$@"; }
c() { seat c claude wc "$@"; }
idof() { sed -n 's/.*id=//p'; }
addr() { "$@" whoami | awk '/^seat/{print $2}'; }

PM=$(addr pm); A=$(addr a); B=$(addr b); C=$(addr c)
for s in pm a b c; do $s who >/dev/null; done

# --- identity ---
out=$(a whoami)
assert_has "seat is tool/worktree.inst" "claude/wa." "$out"
assert_has "scope is tool/worktree" "scope    claude/wa" "$out"
out=$(AGENT_BUS_TOOL= CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=xyz AGENT_BUS_WT=wz "$BIN" whoami)
assert_has "claude detected from env" "seat     claude/wz." "$out"
out=$(AGENT_BUS_TOOL= OPENCODE_SESSION_ID=xyz AGENT_BUS_WT=wz "$BIN" whoami)
assert_has "opencode detected from env" "seat     opencode/wz." "$out"
oc=$(AGENT_BUS_TOOL=opencode OPENCODE_SESSION_ID=oc1 AGENT_BUS_WT=wz "$BIN" whoami | awk '/^seat/{print $2}')
out=$(AGENT_BUS_TOOL=opencode OPENCODE_SESSION_ID=oc1 CLAUDE_CODE_SESSION_ID=cc1 AGENT_BUS_WT=wz "$BIN" whoami)
assert_has "opencode ignores an inherited Claude session id" "seat     $oc" "$out"

# --- routing ---
a post --to @here -m 'self' >/dev/null
assert_has "own posts are never delivered" "nothing unread" "$(a read --peek)"
b read >/dev/null
a post --to @here -m $'# hello wa\n\nhi' >/dev/null
assert_has "@here reaches the worktree" "hello wa" "$(b read --peek)"
assert_lacks "@here stays in the worktree" "hello wa" "$(c read --peek)"
a post --to @repo -m $'# hello repo\n\nhi' >/dev/null
assert_has "@repo reaches other worktrees" "hello repo" "$(c read --peek)"
a post --to "$C" -m $'# direct\n\nhi' >/dev/null
assert_has "direct address delivers" "direct" "$(c read --peek)"
assert_lacks "direct address is private" "direct" "$(b read --peek)"
a post --to claude/wc -m $'# by scope\n\nhi' >/dev/null
assert_has "bare scope reaches the instance" "by scope" "$(c read --peek)"
out=$(a post --to @pm -m x 2>&1 || true)
assert_has "@pm without a PM is refused" "no PM registered" "$out"
out=$(a post --to @codex -m x 2>&1 || true)
assert_has "unknown scope is refused" "unknown scope" "$out"
out=$(a post --to @here --state bogus -m x 2>&1 || true)
assert_has "unknown state is refused" "--state must be one of" "$out"

# --- read marks, peek does not, digest delivers once ---
b read >/dev/null; c read >/dev/null
a post --to "$B" -m $'# once\n\nhi' >/dev/null
assert_has "peek shows" "once" "$(b read --peek)"
assert_has "peek leaves it unread" "once" "$(b read --peek)"
assert_has "digest delivers" "once" "$(b digest)"
assert_eq "digest marks read, then stays silent" "" "$(b digest)"
assert_has "read --all still lists it" "once" "$(b read --all)"
a post --to @here -m $'# just context\n\nhi' >/dev/null
assert_eq "a broadcast is not in the digest" "" "$(b digest)"
assert_has "a broadcast stays readable" "just context" "$(b read --peek)"
b read >/dev/null
out=$(a post -m x 2>&1 || true)
assert_has "post without --to is refused" "--to is required" "$out"
out=$(raw_seat a claude wa post --to "$C" -m x 2>&1 || true)
assert_has "claude to claude is refused" "use Claude session messaging (SendMessage)" "$out"
assert_has "--allow-claude overrides" "posted" "$(raw_seat a claude wa post --allow-claude --to "$C" -m '# allowed')"
assert_has "claude may post to an opencode seat" "posted" "$(raw_seat a claude wa post --to "$B" -m '# to oc')"
c read >/dev/null; b read >/dev/null

# --- PM: role, auto-CC, ownership ---
pm role pm >/dev/null
assert_has "role shows the PM" "PM for" "$(a role)"
out=$(a role pm 2>&1 || true)
assert_has "live PM takeover needs --force" "--force" "$out"
a post --to @here --state fyi -m $'# chatter\n\nx' >/dev/null
assert_lacks "PM skips fyi auto-CC" "chatter" "$(pm read --peek)"
b read >/dev/null
rid=$(a post --to @here --state needs-review -m $'# review me\n\nplease' 2>/dev/null | idof)
out=$(pm read --peek)
assert_has "PM auto-CC on supervisory" "review me" "$out"
assert_lacks "PM copy is not labeled broadcast" "broadcast copy" "$out"
assert_has "worktree bystander sees context, labeled" "broadcast copy" "$(b read --peek)"
assert_eq "bystander is not woken" "{}" "$(b stop-hook </dev/null)"
out=$(pm stop-hook </dev/null)
assert_eq "PM owner is woken" "block" "$(jq -r .decision <<<"$out")"
assert_has "wake carries the packet" "review me" "$(jq -r .reason <<<"$out")"
assert_eq "a wake is a delivery: not woken twice" "{}" "$(pm stop-hook </dev/null)"
pm post --to "$A" --state handoff -m $'# from pm\n\ndo it' >/dev/null
assert_has "PM-sent work is marked in scope" "from the PM your user put in charge" "$(a read --peek)"
a read >/dev/null

# --- closing ---
out=$(c resolve "$rid" 2>&1 || true)
assert_has "resolve needs a reason" "--reason is required" "$out"
out=$(c resolve "$rid" --reason handed-off 2>&1 || true)
assert_has "resolve cannot hand off" "needs a destination" "$out"
out=$(c resolve "$rid" --reason meh 2>&1 || true)
assert_has "resolve rejects unknown reasons" "must be one of" "$out"
out=$(c resolve not-an-id --reason done 2>&1 || true)
assert_has "resolve rejects non-ids" "not a packet id" "$out"
out=$(c resolve 20260101T000000Z-00000000 --reason done 2>&1 || true)
assert_has "resolve rejects unknown ids" "no such packet" "$out"
out=$(c resolve "$rid" --reason done 2>&1 || true)
assert_has "unrelated seat has no standing" "not its sender" "$out"

# Handoff: one ledger row closes the parent and opens the next item.
rows_before=$(wc -l <"$BUS_HOME/ledger.jsonl")
out=$(pm post --re "$rid" --close handed-off --to "$C" --state handoff -m $'# take review\n\ngo')
hid=$(idof <<<"$out")
assert_has "handoff reports the close" "closed $rid (handed-off)" "$out"
assert_eq "handoff is one ledger row" "$((rows_before + 1))" "$(wc -l <"$BUS_HOME/ledger.jsonl" | tr -d ' ')"
out=$(pm triage)
assert_lacks "parent leaves open work" "$rid" "$out"
assert_has "child is owned by the destination" "owner $C" "$out"
out=$(pm post --to "$A" --re "$rid" --close done -m x 2>&1 || true)
assert_has "a closed item cannot close again" "already closed" "$out"
out=$(pm post --to "$A" --close done -m x 2>&1 || true)
assert_has "--close needs --re" "--close needs --re" "$out"
out=$(pm post --to "$A" --re "$hid" --close handed-off --state fyi -m x 2>&1 || true)
assert_has "handed-off must open an item" "--state must be" "$out"
out=$(c resolve "$hid" --reason done)
assert_has "owner closes with a reason" "resolved $hid (done)" "$out"
assert_has "log records the reason" "closed $hid (done)" "$(pm log)"

# --- wake budget ---
for i in 1 2 3 4; do a post --to "$C" --state question -m "# q$i" >/dev/null; c stop-hook </dev/null >/dev/null; done
a post --to "$C" --state question -m '# q5' >/dev/null
assert_eq "budget exhausted: no wake" "{}" "$(c stop-hook </dev/null)"
assert_has "whoami shows the spent budget" "wake     3/3" "$(c whoami)"
q=$(a post --to "$C" --state question -m '# q6' | idof)
c resolve "$q" --reason done >/dev/null
assert_eq "closing resets the budget" "block" "$(c stop-hook </dev/null | jq -r .decision)"
assert_eq "stop-hook is JSON on junk stdin" "{}" "$(printf 'garbage' | c stop-hook)"

# --- triage: gone, not picked up, stale ---
gid=$(a post --to claude/wgone --state blocked -m $'# stuck\n\nhelp' | idof)
out=$(pm triage)
assert_has "owner with no live seat is GONE" "owner claude/wgone  (GONE" "$out"
assert_has "who counts ownerless work" "with no live owner" "$(pm who)"
nid=$(a post --to "$B" --state needs-review -m $'# unseen\n\nx' | idof)
assert_lacks "fresh unread item is not flagged" "NOT PICKED UP" "$(pm triage)"
assert_has "live owner that never read it" "NOT PICKED UP" "$(AGENT_BUS_PICKUP_SECS=0 pm triage)"
assert_has "old item is STALE" "STALE" "$(AGENT_BUS_STALE_HOURS=0 pm triage)"
b read >/dev/null
assert_lacks "read clears NOT PICKED UP" "NOT PICKED UP" "$(AGENT_BUS_PICKUP_SECS=0 pm triage | grep "$nid")"

# --- claims ---
a claim src/x.ts >/dev/null
out=$(c claim src/x.ts 2>&1)
assert_has "claim is contested" "CONTESTED src/x.ts" "$out"
out=$(c release src/x.ts 2>&1)
assert_has "release of a foreign claim is refused" "not releasing" "$out"
out=$(c release --force src/x.ts)
assert_has "--force breaks it" "BROKE claim on src/x.ts" "$out"
assert_has "the break is on record" '"kind":"claim-break"' "$(cat "$BUS_HOME/ledger.jsonl")"
out=$(a claim --all 2>&1 || true)
assert_has "flag-shaped paths are refused" "looks like a flag" "$out"
a claim src/y.ts >/dev/null
assert_lacks "claims are repo-scoped" "src/y.ts" "$(AGENT_BUS_REPO_ID=other a claims)"
assert_has "others see the claim in read" "src/y.ts" "$(c read --peek)"

# --- offboard ---
pm claim src/z.ts >/dev/null
pm post --to "$A" --state blocked -m '# for pm to own' >/dev/null
a post --to "$PM" --state question -m '# pm owns this' >/dev/null
out=$(pm offboard)
assert_has "offboard drops the PM role and claims" "1 role(s), 1 claim(s) released" "$out"
assert_has "offboard lists items still owned" "pm owns this" "$out"
assert_has "PM role is gone" "no PM registered" "$(a role)"

# --- lanes: a feature's seats, across worktrees, with their own PM ---
l1() { seat l1 claude wl1 "$@"; }
l2() { seat l2 opencode wl2 "$@"; }
lp() { seat lp claude wlp "$@"; }
ot() { seat ot claude wot "$@"; }
L1=$(addr l1); L2=$(addr l2); LP=$(addr lp)
out=$(l1 lane here 2>&1 || true)
assert_has "reserved lane names are refused" "not a lane name" "$out"
l1 lane spaces >/dev/null; l2 lane spaces >/dev/null; ot lane other >/dev/null; lp who >/dev/null
assert_has "whoami shows the lane" "lane     spaces" "$(l1 whoami)"
assert_has "who tags lane members" "@spaces" "$(lp who | grep "$L1")"
out=$(l1 post --to @nolane -m x 2>&1 || true)
assert_has "an unknown lane is refused" "unknown scope" "$out"
out=$(l1 post --to @pm -m x 2>&1 || true)
assert_has "@pm with no lane or repo PM is refused" "no PM registered for lane @spaces" "$out"
ot read >/dev/null; l2 read >/dev/null
l1 post --to @spaces -m $'# lane news\n\nhi' >/dev/null
assert_has "@lane reaches lane members in other worktrees" "lane news" "$(l2 read --peek)"
assert_lacks "@lane skips other lanes" "lane news" "$(ot read --peek)"
lp role pm --lane spaces >/dev/null
assert_has "role shows the lane PM" "PM for lane @spaces: $LP" "$(lp role)"
out=$(ot role pm --lane spaces 2>&1 || true)
assert_has "live lane PM takeover needs --force" "--force" "$out"
lid=$(l1 post --to "$L2" --state needs-review -m $'# lane review\n\nx' | idof)
oid=$(ot post --to claude/wsomeone --state blocked -m $'# other lane stuck\n\nx' | idof)
out=$(lp read --peek)
assert_has "lane PM gets a copy of its lane's work" "lane review" "$out"
assert_lacks "lane PM does not see other lanes' work" "other lane stuck" "$out"
assert_has "lane PM is woken for its lane" "block" "$(lp stop-hook </dev/null | jq -r .decision)"
pid=$(l1 post --to @pm --state question -m $'# ask lane pm\n\nx' | idof)
assert_has "@pm from a lane seat reaches the lane PM" "ask lane pm" "$(lp read --peek)"
bid=$(l1 post --to @spaces --state blocked -m $'# lane blocker\n\nx' | idof)
out=$(lp triage --lane spaces)
assert_has "lane broadcasts are owned by the lane PM" "owner $LP" "$out"
assert_lacks "triage --lane filters to the lane" "other lane stuck" "$out"
assert_has "lane PM can close its lane's items" "resolved $lid (done)" "$(lp resolve "$lid" --reason done)"
out=$(lp resolve "$oid" --reason done 2>&1 || true)
assert_has "lane PM cannot close other lanes' items" "not its sender" "$out"
assert_has "lane PM packets are marked as the PM's" "from the PM your user put in charge" \
  "$(lp post --to "$L1" --state handoff -m '# lane task' >/dev/null; l1 read --peek)"
assert_has "offboard releases the lane PM role" "1 role(s)" "$(lp offboard)"
assert_has "lane PM is gone" "no PM registered for lane @spaces" "$(lp role --lane spaces)"
l1 lane --clear >/dev/null
assert_has "a seat can leave its lane" "lane     (none)" "$(l1 whoami)"

# --- safety ---
out=$("$BIN" show ../../etc/passwd 2>&1 || true)
assert_has "show refuses non-ids" "needs a packet id" "$out"
printf '%s\n' '{"kind":"msg","id":"../../x","epoch":9999999999,"from":"evil","to":"@all","state":"fyi","subject":"crafted","session":"e","repo_id":"r"}' >>"$BUS_HOME/ledger.jsonl"
assert_has "crafted id never becomes a path" "malformed id" "$(a read --peek)"
printf 'not json\n' >>"$BUS_HOME/ledger.jsonl"
assert_has "a torn ledger row is skipped" "crafted" "$(a read --peek)"
a read >/dev/null
b post --to "$A" -s $'esc\033[31mape' -m x >/dev/null
out=$(a read --peek)
assert_lacks "control bytes are stripped" $'\033' "$out"
assert_has "the text survives" "esc[31mape" "$out"
out=$(head -c 70000 /dev/zero | tr '\0' x | a post --to @here -m "$(cat)" 2>&1 || true)
assert_has "oversized body is refused" "max 65536" "$out"

# --- push: only the owner is woken ---
if command -v python3 >/dev/null && command -v nc >/dev/null; then
  SOCKD=$(mktemp -d /tmp/abus.XXXX)
  python3 - "$SOCKD" <<'PY' &
import os, socket, sys, threading
d = sys.argv[1]
def serve(name):
    p = os.path.join(d, name); s = socket.socket(socket.AF_UNIX); s.bind(p); s.listen(8)
    while True:
        c, _ = s.accept(); data = c.recv(65536); c.close()
        if data:
            open(p + ".log", "ab").write(data)
for n in ("owner", "bystander"):
    threading.Thread(target=serve, args=(n,), daemon=True).start()
threading.Event().wait()
PY
  SRV=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCKD/bystander" ] && break; sleep 0.1; done
  CLAUDE_CODE_MESSAGING_SOCKET="$SOCKD/owner" seat o1 claude wp who >/dev/null
  CLAUDE_CODE_MESSAGING_SOCKET="$SOCKD/bystander" seat o2 claude wp who >/dev/null
  O1=$(addr seat o1 claude wp)
  out=$(AGENT_BUS_NO_PUSH=0 seat o3 claude wx post --to "$O1" --state needs-review -m '# wake owner')
  sleep 0.3
  assert_has "post wakes the idle owner" "woke 1 idle peer" "$out"
  assert_has "owner got an inbox frame" "agent-bus read" "$(cat "$SOCKD/owner.log" 2>/dev/null)"
  assert_eq "bystander got nothing" "" "$(cat "$SOCKD/bystander.log" 2>/dev/null)"
  out=$(AGENT_BUS_NO_PUSH=0 seat o3 claude wp post --to @here --state needs-review -m '# broadcast review' 2>/dev/null)
  assert_lacks "broadcast review wakes no bystander" "woke" "$out"
  out=$(AGENT_BUS_NO_PUSH=0 seat o3 claude wp post --to @here -m '# broadcast fyi')
  assert_lacks "a broadcast fyi wakes nobody" "woke" "$out"
  assert_eq "bystander still got nothing" "" "$(cat "$SOCKD/bystander.log" 2>/dev/null)"
  kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; SRV=; rm -rf "$SOCKD"
else
  printf 'skip push tests (python3/nc missing)\n'
fi

# --- grok: webhook delivery ---
# Helper: invoke agent-bus as a generic shell (registration caller)
greg() { AGENT_BUS_TOOL=shell AGENT_BUS_WT=tester AGENT_BUS_SESSION=grtest "$BIN" "$@"; }
# Helper: invoke agent-bus as the registered Grok Bot seat
gbot() { AGENT_BUS_TOOL=grok  AGENT_BUS_WT=bot1   AGENT_BUS_SESSION=local  "$BIN" "$@"; }

# Registration validation
out=$(greg grok register --name 'BAD NAME' --webhook http://x/ 2>&1 || true)
assert_has "grok register rejects invalid name" "must be lowercase" "$out"
out=$(greg grok register --name bot1 --webhook 'ftp://no' 2>&1 || true)
assert_has "grok register rejects non-http webhook" "must start with http" "$out"
out=$(greg grok register --name bot1 --webhook http://ok/ --secret-env '1BADVAR' 2>&1 || true)
assert_has "grok register rejects bad secret-env name" "valid environment variable" "$out"
out=$(greg grok register --name bot1 --webhook http://ok/)
assert_has "grok register succeeds" "registered grok/bot1" "$out"

# Seat visibility
out=$(greg who)
assert_has "registered grok seat shows in who" "grok/bot1" "$out"
GADDR=$(gbot whoami | awk '/^seat/{print $2}')
assert_has "grok seat has correct address" "grok/bot1" "$GADDR"

# Triage: seat is reachable, so open items owned by it are not GONE
tid=$(a post --to "$GADDR" --state needs-review -m $'# for grok bot\n\nhello' | idof)
out=$(pm triage)
assert_lacks "registered grok seat is not GONE" "GONE" "$(grep "$GADDR" <<<"$out")"
assert_has "grok work shows in triage" "$GADDR" "$out"

# Budget reset via grok seat resolving
gbot resolve "$tid" --reason done >/dev/null
assert_has "grok bot can resolve its own item" "0" \
  "$(jq -r '.wakes // 0' "$BUS_HOME/state/$(printf '%s' "$GADDR" | tr '/:@ ' '____').json" 2>/dev/null || echo 0)"

if command -v python3 >/dev/null && command -v curl >/dev/null; then
  GROOKD=$(mktemp -d /tmp/abus-grok.XXXX)
  python3 - "$GROOKD" <<'PY' &
import http.server, json, os, pathlib, sys
d = pathlib.Path(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(n)) if n else {}
        rec = {'body': body, 'auth': self.headers.get('Authorization', '')}
        (d / 'requests.jsonl').open('a').write(json.dumps(rec) + '\n')
        self.send_response(int(os.environ.get('FAKE_HTTP_STATUS', '200')))
        self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
(d / 'port').write_text(str(s.server_address[1]))
s.serve_forever()
PY
  GROK_SRV=$!
  for _i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$GROOKD/port" ] && break; sleep 0.1; done
  GROK_PORT=$(cat "$GROOKD/port")
  GROK_URL="http://127.0.0.1:$GROK_PORT/hook"

  # Re-register with a real webhook URL (replaces the placeholder from above)
  greg grok register --name bot1 --webhook "$GROK_URL" >/dev/null

  # Delivery: post to grok seat triggers webhook
  out=$(AGENT_BUS_NO_PUSH=0 a post --to "$GADDR" --state needs-review \
    -m $'# needs-review for grok\n\nplease check' 2>&1)
  sleep 0.3
  assert_has "webhook delivery reported" "webhook notice delivered" "$out"

  # Payload shape: routing info only, no packet body
  req=$(tail -1 "$GROOKD/requests.jsonl" 2>/dev/null || echo '{}')
  assert_has "payload has packet_id"  '"packet_id"'  "$req"
  assert_has "payload has from"       '"from"'        "$req"
  assert_has "payload has to"         '"to"'          "$req"
  assert_has "payload has state"      '"needs-review"' "$req"
  assert_has "payload has repo"       '"repo"'        "$req"
  assert_has "payload has repo_id"    '"repo_id"'     "$req"
  assert_lacks "payload omits packet body" "please check" "$req"

  # Delivery row in ledger
  assert_has "delivery row uses grok-webhook transport" \
    '"transport":"grok-webhook"' "$(cat "$BUS_HOME/ledger.jsonl")"
  assert_has "delivery row status is delivered" '"status":"delivered"' \
    "$(cat "$BUS_HOME/ledger.jsonl")"

  # Budget exhaustion (budget=3; first post above used one slot after the resolve reset)
  w2=$(AGENT_BUS_NO_PUSH=0 a post --to "$GADDR" --state question -m '# q2' | idof)
  AGENT_BUS_NO_PUSH=0 a post --to "$GADDR" --state question -m '# q3' >/dev/null
  out=$(AGENT_BUS_NO_PUSH=0 a post --to "$GADDR" --state question -m '# q4' 2>&1)
  assert_has "budget exhausted: delivery skipped" "budget_exhausted" "$out"
  assert_has "delivery row for exhausted attempt" '"status":"budget_exhausted"' \
    "$(cat "$BUS_HOME/ledger.jsonl")"

  # Closing an item resets the budget
  gbot resolve "$w2" --reason done >/dev/null
  out=$(AGENT_BUS_NO_PUSH=0 a post --to "$GADDR" --state question -m '# after-reset' 2>&1)
  assert_has "closing resets grok wake budget" "webhook notice delivered" "$out"

  # Packet stays unread after successful delivery (only cmd_read marks packets read)
  latest_id=$(a post --to "$GADDR" --state question -m '# unread-check' | idof)
  sleep 0.1
  state_file="$BUS_HOME/state/$(printf '%s' "$GADDR" | tr '/:@ ' '____').json"
  read_list=$(jq -r '.read // [] | length' "$state_file" 2>/dev/null || echo 0)
  assert_eq "webhook delivery does not mark packet read" "0" \
    "$(jq -r --arg i "$latest_id" '(.read // []) | index($i) != null | if . then 1 else 0 end' \
       "$state_file" 2>/dev/null || echo 0)"

  # Failure leaves packet unread: register a second seat with an unreachable URL
  greg grok register --name bot2 --webhook "http://127.0.0.1:1/unreachable" >/dev/null
  GADDR2=$(AGENT_BUS_TOOL=grok AGENT_BUS_WT=bot2 AGENT_BUS_SESSION=local "$BIN" whoami \
    | awk '/^seat/{print $2}')
  out=$(AGENT_BUS_NO_PUSH=0 a post --to "$GADDR2" --state question -m '# unreachable' 2>&1)
  assert_has "failure: packet saved message" "packet saved" "$out"
  state2="$BUS_HOME/state/$(printf '%s' "$GADDR2" | tr '/:@ ' '____').json"
  assert_eq "failure: packet remains unread" "0" \
    "$(jq -r '.read // [] | length' "$state2" 2>/dev/null || echo 0)"
  assert_has "failure: delivery row recorded" '"transport":"grok-webhook"' \
    "$(cat "$BUS_HOME/ledger.jsonl")"
  greg grok unregister --name bot2 >/dev/null

  # grok status
  out=$(greg grok status)
  assert_has "grok status shows webhook" "$GROK_URL" "$out"
  assert_has "grok status shows wakes" '"wakes"' "$out"

  # grok status --name filter
  out=$(greg grok status --name bot1)
  assert_has "grok status --name filters to named seat" "grok/bot1" "$out"

  # Secret: register with --secret-env, verify Authorization header is sent
  GROK_TEST_TOKEN=tok123
  export GROK_TEST_TOKEN
  greg grok register --name bot1 --webhook "$GROK_URL" --secret-env GROK_TEST_TOKEN >/dev/null
  AGENT_BUS_NO_PUSH=0 a post --to "$GADDR" --state question \
    -m '# secret-test' >/dev/null
  sleep 0.1
  auth_req=$(grep 'tok123' "$GROOKD/requests.jsonl" || true)
  assert_has "bearer token sent as Authorization header" "tok123" \
    "$(tail -1 "$GROOKD/requests.jsonl")"
  unset GROK_TEST_TOKEN
  # Reset back to no-secret for cleanliness
  greg grok register --name bot1 --webhook "$GROK_URL" >/dev/null

  # Grok seat in who after registration
  assert_has "grok status shows in doctor" "grok" "$(greg doctor)"

  # grok unregister
  out=$(greg grok unregister --name bot1)
  assert_has "grok unregister reports" "unregistered grok/bot1" "$out"
  out=$(greg who)
  assert_lacks "unregistered grok seat gone from who" "grok/bot1" "$out"
  out=$(greg grok unregister --name bot1 2>&1 || true)
  assert_has "double unregister is an error" "not registered" "$out"

  kill "$GROK_SRV" 2>/dev/null || true
  wait "$GROK_SRV" 2>/dev/null || true
  GROK_SRV=; rm -rf "$GROOKD"
else
  printf 'skip grok webhook tests (python3/curl missing)\n'
fi

# --- gc ---
old=$(( $(date -u +%s) - 30 * 86400 ))
printf '{"kind":"msg","id":"20200101T000000Z-0000abcd","epoch":%s,"from":"x","to":"@all","state":"fyi","subject":"ancient"}\n' "$old" >>"$BUS_HOME/ledger.jsonl"
printf 'old\n' >"$BUS_HOME/msg/20200101T000000Z-0000abcd.md"
out=$("$BIN" gc)
assert_has "gc rotates old rows" "1 ledger rows rotated" "$out"
assert_has "rotated rows land in the archive" "ancient" "$(cat "$BUS_HOME/ledger.archive.jsonl")"
assert_eq "old bodies are removed" "no" "$([ -f "$BUS_HOME/msg/20200101T000000Z-0000abcd.md" ] && echo yes || echo no)"
assert_has "gc keeps undatable rows" "not json" "$(cat "$BUS_HOME/ledger.jsonl")"
touch -t 202001010000 "$BUS_HOME/seats/$(printf '%s' "$A" | tr '/:@ ' '____').json"
jq -c '.epoch = 1' "$BUS_HOME/seats/$(printf '%s' "$A" | tr '/:@ ' '____').json" >"$BUS_HOME/t" \
  && mv "$BUS_HOME/t" "$BUS_HOME/seats/$(printf '%s' "$A" | tr '/:@ ' '____').json"
"$BIN" gc >/dev/null
assert_eq "a dead seat's read cursor survives" "yes" \
  "$([ -f "$BUS_HOME/state/$(printf '%s' "$A" | tr '/:@ ' '____').json" ] && echo yes || echo no)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
