#!/bin/bash
# ./agent.sh xcode <Xcode.xip> [platform ...]        new Xcode: rebuild xcode-base, then agent-base
#   platform: iOS | watchOS | tvOS | visionOS, optionally with a version ("iOS 26.4"),
#   or a runtime .dmg next to the .xip. Default: sdk_platforms in agent.pkr.hcl, else latest iOS.
# ./agent.sh tools                                   new tools/rules: rebuild agent-base only
# ./agent.sh run [--gui] <repo> <prompt-file> [branch]    unattended job in a throwaway VM
# ./agent.sh session [--gui] <repo> [branch]              attended Claude Code session in a throwaway VM
#   --gui  show the VM's window (the agent user's desktop), e.g. to watch the Simulator
# ./agent.sh denials                                 summarize denied and failed tool calls across all runs
#
# Builds need:      PKR_VAR_admin_password   (admin password inside the VMs)
# Jobs & sessions:  Claude credentials, ONE of:
#                     CLAUDE_CODE_OAUTH_TOKEN  from `claude setup-token` (Pro/Max/Team/Enterprise subscription)
#                     ANTHROPIC_API_KEY        Console API key (pay per token)
#                   GH_TOKEN (fine-grained, READ-ONLY: this is what prevents pushes)
# Put these in .env (copy env.template), or export them in your shell (the shell wins).
#
# Code in:  the starting branch's committed history, as a git bundle (uncommitted work stays behind).
# Code out: new commits on agent/<name>, fetched into your repo as a bundle. Uncommitted changes
#           left in the VM become a WIP commit (sessions ask first). This also happens on Ctrl-C.
# Audit:    every tool call is logged by a hook in the VM and captured live on your Mac; each run
#           gets ~/agent-jobs/<run>/denials.md (denied and failed calls, and what the agent did next).
#           Needs jq on your Mac (brew install jq).
set -euo pipefail
PKR="$(cd "$(dirname "$0")" && pwd)/agent.pkr.hcl"

# Load .env next to this script (template: env.template). Variables already set in the shell win.
if [ -f "$(dirname "$PKR")/.env" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    k="${BASH_REMATCH[1]}" v="${BASH_REMATCH[2]}"
    v="${v%\"}" v="${v#\"}" v="${v%\'}" v="${v#\'}"
    [ -n "${!k:-}" ] || export "$k=$v"
  done < "$(dirname "$PKR")/.env"
fi

# ---------- image builds ----------

swap() { tart delete "$1" 2>/dev/null || true; tart rename "$1-next" "$1"; }

build() {  # build <layer> [packer args...]  -> builds "<layer>-base-next", then swaps it in
  local layer="$1"; shift
  tart delete "$layer-base-next" 2>/dev/null || true
  packer init "$PKR" >/dev/null
  packer build -only="$layer.*" -var suffix=-next "$@" "$PKR"
  swap "$layer-base"
}

# ---------- throwaway VMs ----------

# Files that define the agent's limits. Commits touching them are quarantined, not delivered.
PROTECTED_RE='(^|/)(claude(\.local)?\.md|agents\.md|gemini\.md|\.mcp\.json|\.cursorrules)$|(^|/)(\.claude|\.cursor)/|(^|/)\.github/(copilot-instructions\.md|instructions/)'

OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=60)
AUDIT_PID="" GUI=0 KIND="" REPO="" BASE="" BRANCH="" OUT="" VM="" IP=""

rsh() { ssh "${OPTS[@]}" agent@"$IP" "$@"; }   # run a command in the VM as agent

# start_vm <job|session> <repo> [branch]: clone agent-base, boot it, copy the branch in.
start_vm() {
  command -v jq >/dev/null || { echo "agent.sh needs jq on your Mac: brew install jq" >&2; exit 1; }
  KIND="$1"; REPO="$(cd "$2" && pwd)"
  BASE="${3:-$(git -C "$REPO" branch --show-current)}"
  # Claude credentials: subscription token if set, else API key. Only one is passed into the VM,
  # because Claude Code prefers ANTHROPIC_API_KEY over CLAUDE_CODE_OAUTH_TOKEN when both exist.
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    AUTH_VAR=CLAUDE_CODE_OAUTH_TOKEN; AUTH_VAL="$CLAUDE_CODE_OAUTH_TOKEN"
  elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    AUTH_VAR=ANTHROPIC_API_KEY; AUTH_VAL="$ANTHROPIC_API_KEY"
  else
    echo "Set CLAUDE_CODE_OAUTH_TOKEN (subscription, from 'claude setup-token') or ANTHROPIC_API_KEY" >&2; exit 1
  fi
  echo "Claude auth: $AUTH_VAR"
  : "${GH_TOKEN:?set GH_TOKEN (read-only fine-grained token)}"
  git -C "$REPO" rev-parse --verify -q "$BASE" >/dev/null || { echo "No branch '$BASE' in $REPO" >&2; exit 1; }
  [ -z "$(git -C "$REPO" status --porcelain)" ] ||
    echo "Note: $REPO has uncommitted changes; they are NOT copied into the VM."

  local name ORIGIN
  name="$KIND-$(date +%Y%m%d-%H%M%S)"
  BRANCH="agent/$name"; OUT="$HOME/agent-jobs/$name"; mkdir -p "$OUT"
  ORIGIN="$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -E 's#^git@github\.com:#https://github.com/#' || true)"

  git -C "$REPO" bundle create "$OUT/in.bundle" "$BASE"

  tart clone agent-base "$name"; VM="$name"
  trap finish EXIT
  trap 'exit 130' INT TERM          # make Ctrl-C go through finish()
  if [ "$GUI" = 1 ]; then
    tart run --net-softnet "$VM" >"$OUT/tart.log" 2>&1 &
    echo "The VM window will open. Don't close it: end the session from this Terminal so commits are collected."
  else
    tart run --no-graphics --net-softnet "$VM" >"$OUT/tart.log" 2>&1 &
  fi
  echo "Booting $VM..."
  local ip
  until ip=$(tart ip "$VM" 2>/dev/null); do sleep 2; done
  until ssh "${OPTS[@]}" agent@"$ip" true 2>/dev/null; do sleep 2; done
  IP="$ip"

  scp -q "${OPTS[@]}" "$OUT/in.bundle" agent@"$IP":
  printf 'export %s=%q\nexport GH_TOKEN=%q\nexport TART_AGENT_VM=1\nexport AGENT_ATTENDED=%q\nexport AGENT_BASE_BRANCH=%q\nexport AGENT_BRANCH=%q\n' \
    "$AUTH_VAR" "$AUTH_VAL" "$GH_TOKEN" "$([ "$KIND" = session ] && echo 1 || echo 0)" "$BASE" "$BRANCH" |
    rsh 'umask 077; cat > ~/.job-env'

  rsh bash -l -s -- "$BASE" "$BRANCH" "$ORIGIN" <<'SETUP'
set -e
git clone -q -b "$1" ~/in.bundle ~/work && cd ~/work
git switch -q -c "$2"
git remote remove origin
if [ -n "$3" ]; then
  git remote add origin "$3"                       # fetch-only, via the read-only token
  git remote set-url --push origin PUSH-DISABLED
fi
# Open the project in Xcode's headless MCP server, so Xcode's tools can work on it.
# perl's alarm caps the wait, since nothing here should block a run from starting.
proj="$(find . -maxdepth 2 -name '*.xcworkspace' -not -path '*.xcodeproj/*' | sort | head -1)"
[ -n "$proj" ] || proj="$(find . -maxdepth 2 -name '*.xcodeproj' | sort | head -1)"
if [ -n "$proj" ]; then
  if perl -e 'alarm 120; exec @ARGV' xcrun mcp-server open "$PWD/${proj#./}" >/dev/null 2>&1; then
    echo "Opened ${proj#./} for Xcode's MCP tools."
  else
    echo "Note: couldn't open ${proj#./} in Xcode's MCP server; Claude can open it with its XcodeOpenWorkspace tool."
  fi
fi
SETUP
  start_audit
}

# ---------- audit log: denied and failed tool calls ----------

# redact: replace the exact Claude credential and GitHub token values with placeholders (stdin -> stdout).
redact() {
  R1="${AUTH_VAL:-}" R1N="${AUTH_VAR:-CLAUDE}" R2="${GH_TOKEN:-}" awk '
    function rep(s, v, name,   out, i) {
      if (v == "") return s
      out = ""
      while ((i = index(s, v)) > 0) { out = out substr(s, 1, i - 1) "[REDACTED:" name "]"; s = substr(s, i + length(v)) }
      return out s
    }
    { line = rep($0, ENVIRON["R1"], ENVIRON["R1N"]); line = rep(line, ENVIRON["R2"], "GH_TOKEN"); print line; fflush() }'
}
redact_file() { redact < "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }

# Follow the VM's audit log over SSH for the whole run, so each line is saved on your Mac as it's
# written and can't be changed afterwards.
start_audit() {
  rsh 'mkdir -p ~/.agent-audit && touch ~/.agent-audit/events.jsonl'
  ( ssh -n "${OPTS[@]}" agent@"$IP" 'exec tail -n +1 -F ~/.agent-audit/events.jsonl' 2>/dev/null |
      redact > "$OUT/audit.jsonl" ) &
  AUDIT_PID=$!
}

# Stop following, and fetch the VM's own copy of the log (to spot tampering) and the session transcripts.
stop_audit() {
  if [ -n "$AUDIT_PID" ]; then
    sleep 1
    rsh 'pkill -x tail' >/dev/null 2>&1 || true
    wait "$AUDIT_PID" 2>/dev/null || true
    AUDIT_PID=""
  fi
  if scp -q "${OPTS[@]}" agent@"$IP":.agent-audit/events.jsonl "$OUT/audit.vm.jsonl" 2>/dev/null; then
    redact_file "$OUT/audit.vm.jsonl"
  fi
  if scp -q -r "${OPTS[@]}" agent@"$IP":.claude/projects "$OUT/transcripts" 2>/dev/null; then
    find "$OUT/transcripts" -type f -name '*.jsonl' | while read -r f; do redact_file "$f"; done
  fi
  return 0
}

# The deny rules from agent.pkr.hcl, as a JSON array (used to name the rule behind each denial).
deny_rules_json() {
  sed -n '/^variable "claude_deny_rules"/,/^}/p' "$PKR" | grep -oE '^[[:space:]]*"[^"]+"' |
    sed -E 's/^[[:space:]]*"//; s/"$//' | jq -R . | jq -sc .
}

# Live, readable view of a job's stream-json output.
render_stream() {
  jq -Rrj --unbuffered '
    (fromjson? // null) as $j
    | (if ($j | type) == "object" then $j else {type: "raw", text: .} end) as $e
    | if $e.type == "raw" then $e.text + "\n"
      elif $e.type == "assistant" then
        ($e.message.content[]? | select(type == "object")
         | if .type == "text" then .text + "\n"
           elif .type == "tool_use" then "→ \(.name): \(.input.command // .input.file_path // .input.pattern // (.input | tojson))\n"
           else empty end)
      elif $e.type == "user" then
        ($e.message.content[]? | select(type == "object" and .type == "tool_result" and .is_error == true)
         | "✗ \((.content | if type == "string" then . else (map(.text? // "") | join(" ")) end) | split("\n")[0])\n")
      elif $e.type == "result" then "\n== Result ==\n\($e.result // "")\n"
      else empty end'
}

IFS= read -r -d '' CALLS_JQ <<'JQ' || true   # (read, not $(cat), for macOS's bash 3.2)
# Builds calls.json from the audit log, the job stream or session transcript, and the deny rules.
def esc: gsub("(?<c>[.+?^${}()|\\[\\]\\\\])"; "\\\(.c)");
def bashre: esc | gsub("\\*"; ".*") | "^" + . + "$";
def pathre: sub("^//"; "/") | sub("^~/"; "/Users/agent/") | esc
  | gsub("\\*\\*/"; "\u0001") | gsub("\\*\\*"; "\u0002") | gsub("\\*"; "[^/]*")
  | gsub("\u0001"; "(.*/)?") | gsub("\u0002"; ".*") | "^" + . + "$";
def segs: [., splits("\\s*(&&|\\|\\||;|\\|)\\s*")] | map(sub("^\\s+"; "") | sub("\\s+$"; "") | select(length > 0));
def rule_for($tool; $input):
  first(
    $rules[] as $r
    | if $tool == "Bash" and ($r | startswith("Bash(")) then
        ($r | .[5:-1] | bashre) as $re
        | select(any(($input.command // "") | segs[]; test($re))) | $r
      elif ($tool | IN("Edit", "Write", "MultiEdit", "NotebookEdit")) and ($r | startswith("Edit(")) then
        ($r | .[5:-1] | pathre) as $re
        | select(($input.file_path // $input.notebook_path // "") | test($re)) | $r
      elif $r == $tool then $r
      else empty end
  ) // null;
def lines: split("\n") | map(select(length > 0) | (fromjson? // empty) | select(type == "object"));

($audit | lines | map((.event // {}) + {ts: .ts})) as $ev
| ($msgs | lines) as $m
| [$m[] | select(.type == "result") | .permission_denials[]? | .tool_use_id] as $sden
| ([$m[] | select(.type == "assistant") | .message.content[]? | select(type == "object")]
   | reduce .[] as $b ({last: null, said: {}};
       if $b.type == "text" then .last = (if .last then .last + "\n" else "" end) + $b.text
       elif $b.type == "tool_use" then .said[$b.id] = .last | .last = null
       else . end)
   | .said) as $said
| (reduce ($ev[] | select(.tool_use_id != null)) as $x ({order: [], by: {}};
     (if .by[$x.tool_use_id] == null then .order += [$x.tool_use_id] else . end)
     | .by[$x.tool_use_id] += [$x])) as $g
| [ $g.order[] as $id | $g.by[$id] as $evs
    | ($evs | map(select(.hook_event_name == "PreToolUse")) | .[0]) as $pre
    | ($evs | map(select(.hook_event_name == "PermissionDenied")) | .[0]) as $den
    | ($evs | map(select(.hook_event_name == "PostToolUseFailure")) | .[0]) as $fail
    | ($evs | map(select(.hook_event_name == "PostToolUse")) | .[0]) as $post
    | ($pre // $den // $fail // $post) as $any
    | ($post.tool_response? // null) as $resp
    | (if ($resp | type) == "object" then ($resp.exit_code // $resp.exitCode // $resp.returnCode // null) else null end) as $code
    | { id: $id, ts: $any.ts, tool: $any.tool_name, input: ($any.tool_input // {}),
        status: (if $den or ($sden | any(. == $id)) then "denied"
                 elif $fail then (if $fail.is_interrupt then "interrupted" else "failed" end)
                 elif $post then (if ($code | type) == "number" and $code != 0 then "failed" else "ok" end)
                 else "blocked" end),
        reason: (if $den then ($den.reason // $den.message // $den.error // null)
                 elif $fail then ($fail.error // null)
                 elif ($code | type) == "number" and $code != 0 then
                   "exit code \($code)" + (if (($resp.stderr // "") | length) > 0 then ": " + $resp.stderr else "" end)
                 else null end),
        said: ($said[$id] // null) }
    | .rule = (if .status == "denied" or .status == "blocked" then rule_for(.tool; .input) else null end) ]
  as $calls
| { run: $run, kind: $kind,
    recorded: ($audit | lines | length),
    vm_lines: ($vmlines | tonumber? // null),
    stream_denials: ($sden | length),
    calls: $calls,
    orphan_denials: [$ev[] | select(.tool_use_id == null and .hook_event_name == "PermissionDenied")] }
JQ

IFS= read -r -d '' REPORT_JQ <<'JQ' || true   # (read, not $(cat), for macOS's bash 3.2)
# Renders denials.md from calls.json.
def fence: "~~~~\n" + . + "\n~~~~";
def indent: split("\n") | map("  " + .) | join("\n");
def quote: split("\n") | map("> " + .) | join("\n");
def cmdtext: if .tool == "Bash" then (.input.command // "") else (.input | tojson) end;
def count($s): map(select(.status == $s)) | length;
.calls as $c
| [ "# Denials and failures: \(.run)", "",
    "Tool calls recorded: \($c | length). Denied: \($c | count("denied")). Blocked (no result): \($c | count("blocked")). Failed: \($c | count("failed")). Interrupted: \($c | count("interrupted")).",
    (if .vm_lines != null and .vm_lines < .recorded then
       "\n**Warning:** the VM's copy of the audit log has \(.vm_lines) lines but \(.recorded) were captured live. It was truncated or replaced during the run."
     else empty end),
    (if .stream_denials > 0 then "Claude Code's final result listed \(.stream_denials) permission denials." else empty end),
    "",
    "**denied**: refused by a deny rule or auto mode. **blocked**: started but no result was recorded, usually a deny rule (or the run ended). **failed**: ran and returned an error. Commands are shown in full; credential values are replaced with `[REDACTED:…]`.",
    "",
    ( $c | to_entries[] | select(.value.status != "ok") | .key as $i | .value as $x
      | ($c[$i + 1:] | (map(.status) | index("ok")) as $ok | .[0:([($ok // 4) + 1, 5] | min)]) as $next
      | ( "## \($i + 1). \($x.status | ascii_upcase): \($x.tool)" + (if $x.ts then "  (\($x.ts))" else "" end)),
        (if $x.rule then "Matching deny rule: `\($x.rule)`" else empty end),
        (if $x.reason then "Reason: \($x.reason | tostring)" else empty end),
        "",
        ($x | cmdtext | fence),
        (if $x.said then "\nClaude, just before:\n\n" + ($x.said | quote) else empty end),
        "",
        (if ($next | length) > 0 then "**What it did next:**" else "**What it did next:** nothing; the run ended." end),
        ( $next[] | "",
          "- `\(.status)` **\(.tool)**" + (if .rule then " (rule `\(.rule)`)" else "" end) + (if .reason then ": \(.reason | tostring | split("\n")[0])" else "" end),
          (if .said then ("\n" + (.said | quote) | indent) else empty end),
          ("" , (cmdtext | fence | indent)) ),
        (if ($x.status == "denied" or $x.status == "blocked") and ($next | any(.status == "denied" or .status == "blocked")) then
           "\n**Possible workaround attempt:** another call was blocked right after this one. Check whether it tried to do the same thing another way."
         else empty end),
        "" ),
    ( if (.orphan_denials | length) > 0 then
        "## Denials not tied to a tool call", "",
        (.orphan_denials[] | "- \(.ts // ""): \(tojson)")
      else empty end )
  ] | join("\n")
JQ

IFS= read -r -d '' SUMMARY_JQ <<'JQ' || true   # (read, not $(cat), for macOS's bash 3.2)
# Aggregates calls.json files from many runs into one markdown summary.
def cmdtext: if .tool == "Bash" then (.input.command // "") else (.input | tojson) end;
def key: .rule // ("(no rule) \(.status): " + (if .tool == "Bash" then ((.input.command // "") | split(" ")[0]) else .tool end));
[ .[] | .run as $run | .calls[] | select(.status != "ok") | . + {run: $run} ]
| group_by(key)
| map({ key: (.[0] | key), statuses: (map(.status) | unique | join(", ")), count: length,
       runs: (map(.run) | unique), examples: (map(cmdtext) | unique | .[0:3]) })
| sort_by(-.count)
| [ "# Denials and failures across runs", "",
    "Grouped by the deny rule that matched (or, for failures, by the command). Use this to decide what to loosen or tighten in `claude_deny_rules`.", "",
    ( .[] | "## \(.key)", "",
            "\(.count) time(s) in \(.runs | length) run(s) (\(.statuses)). Latest run: \(.runs | max).", "",
            (.examples[] | "~~~~\n" + . + "\n~~~~"), "" ) ]
| join("\n")
JQ

# make_report: build calls.json and denials.md for this run.
make_report() {
  touch "$OUT/audit.jsonl"
  local msgs="$OUT/.messages.jsonl" vmlines=""
  if [ -f "$OUT/events.stream.jsonl" ]; then
    cp "$OUT/events.stream.jsonl" "$msgs"
  else
    find "$OUT/transcripts" -type f -name '*.jsonl' -exec cat {} + > "$msgs" 2>/dev/null || : > "$msgs"
  fi
  [ -f "$OUT/audit.vm.jsonl" ] && vmlines="$(wc -l < "$OUT/audit.vm.jsonl" | tr -d ' ')"
  jq -n --rawfile audit "$OUT/audit.jsonl" --rawfile msgs "$msgs" --argjson rules "$(deny_rules_json)" \
    --arg run "$(basename "$OUT")" --arg kind "$KIND" --arg vmlines "$vmlines" "$CALLS_JQ" > "$OUT/calls.json"
  jq -r "$REPORT_JQ" "$OUT/calls.json" > "$OUT/denials.md"
  rm -f "$msgs"
  echo
  jq -r '"Tool calls: \(.calls | length); denied or blocked: \([.calls[] | select(.status == "denied" or .status == "blocked")] | length); failed: \([.calls[] | select(.status == "failed" or .status == "interrupted")] | length)."' "$OUT/calls.json"
  echo "Report: $OUT/denials.md"
}

# ./agent.sh denials: summary across all runs that have a calls.json.
show_denials() {
  local files=()
  for f in "$HOME"/agent-jobs/*/calls.json; do [ -f "$f" ] && files+=("$f"); done
  [ ${#files[@]} -gt 0 ] || { echo "No runs with an audit report yet (~/agent-jobs/*/calls.json)."; exit 0; }
  jq -s -r "$SUMMARY_JQ" "${files[@]}" | tee "$HOME/agent-jobs/DENIALS.md"
  echo; echo "Saved to ~/agent-jobs/DENIALS.md"
}

wip_commit() {
  rsh 'cd ~/work && git add -A && git commit -q -m "WIP: uncommitted changes at end of session"' &&
    echo "Committed them as a WIP commit."
}

# collect: turn leftovers into a WIP commit, bundle new commits, fetch them into your repo.
collect() {
  local dirty answer
  dirty="$(rsh 'cd ~/work 2>/dev/null && git status --porcelain' 2>/dev/null || true)"
  if [ -n "$dirty" ]; then
    echo; echo "Uncommitted changes in the VM:"; echo "$dirty"
    if [ "$KIND" = session ] && [ -t 0 ]; then
      read -rp "Keep them as a WIP commit? [Y/n] " answer || answer=y
      case "$answer" in [Nn]*) echo "Discarding them." ;; *) wip_commit || true ;; esac
    else
      wip_commit || true
    fi
  fi

  if rsh "cd ~/work && git bundle create -q ~/out.bundle '$BASE..$BRANCH'" 2>/dev/null &&
     scp -q "${OPTS[@]}" agent@"$IP":out.bundle "$OUT/" 2>/dev/null; then
    # Fetch into a temporary ref first, so commits that touch the agent's own limits never
    # become a normal agent/ branch.
    local tmp="refs/agent-incoming/${BRANCH#agent/}" protected
    git -C "$REPO" fetch -q "$OUT/out.bundle" "$BRANCH:$tmp"
    protected="$(git -C "$REPO" diff --name-only "$BASE...$tmp" | grep -Ei "$PROTECTED_RE" || true)"
    if [ -n "$protected" ]; then
      local q="agent-quarantine/${BRANCH#agent/}"
      git -C "$REPO" branch -q -f "$q" "$tmp"
      printf '%s\n' "$protected" > "$OUT/PROTECTED-FILES-CHANGED.txt"
      echo
      echo "BLOCKED: the agent's commits change files that define its own limits:"
      printf '  %s\n' $protected
      echo "They were NOT put on $BRANCH. They're quarantined on $q for inspection:"
      echo "  git -C \"$REPO\" diff $BASE...$q -- $(echo $protected)"
    else
      git -C "$REPO" branch -q -f "$BRANCH" "$tmp"
      echo; echo "Commits are on $BRANCH. Review: git -C \"$REPO\" log --stat $BASE..$BRANCH"
    fi
    git -C "$REPO" update-ref -d "$tmp"
  else
    echo; echo "No new commits."
  fi
}

finish() {
  local rc=$?
  trap - EXIT INT TERM
  [ -n "$IP" ] && { collect || echo "Could not collect commits from the VM." >&2; }
  [ -n "$IP" ] && { stop_audit || true; }
  if [ -n "$VM" ]; then
    tart stop "$VM" >/dev/null 2>&1 || true
    tart delete "$VM" || true
  fi
  [ -n "$IP" ] && { make_report || echo "Could not build the audit report." >&2; }
  [ -n "$OUT" ] && echo "Logs and bundles: $OUT"
  exit "$rc"
}

run_job() {  # <repo> <prompt-file> [branch]
  [ -f "${2:-}" ] || { echo "Prompt file not found: ${2:-}" >&2; exit 1; }
  local prompt="$2"
  start_vm job "$1" "${3:-}"
  cp "$prompt" "$OUT/prompt.md"
  scp -q "${OPTS[@]}" "$OUT/prompt.md" agent@"$IP":
  # Raw events go to events.stream.jsonl; a readable version is shown and saved as agent.log.
  rsh bash -l -s <<'REMOTE' 2>&1 | redact | tee "$OUT/events.stream.jsonl" | render_stream | tee "$OUT/agent.log" || true
. ~/.job-env
cd ~/work
claude -p "$(cat ~/prompt.md)" --permission-mode auto --output-format stream-json --verbose || echo "claude exited with $?"
REMOTE
}

run_session() {  # <repo> [branch]
  start_vm session "$1" "${2:-}"
  echo
  echo "Claude Code is starting in the VM, in ~/work on $BRANCH."
  echo "Quitting Claude leaves you in a shell there; exit that shell to end the session."
  [ "$GUI" = 1 ] && echo "To watch the Simulator, run 'open -a Simulator' in the VM (or ask Claude to)."
  echo
  ssh -t "${OPTS[@]}" agent@"$IP" "zsh -lc 'cd ~/work && . ~/.job-env && { claude; exec zsh -l; }'" || true
}

# ---------- dispatch ----------

case "${1:-}" in
  xcode)
    : "${PKR_VAR_admin_password:?export PKR_VAR_admin_password first}"
    [ -f "${2:-}" ] || { echo "Usage: $0 xcode <Xcode.xip> [platform ...]" >&2; exit 1; }
    XIP="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
    shift 2
    PLATFORM_ARGS=()
    if [ $# -gt 0 ]; then          # e.g. iOS "iOS 26.4" watchOS  ->  sdk_platforms=["iOS","iOS 26.4","watchOS"]
      list=""
      for p in "$@"; do list="$list\"$p\","; done
      PLATFORM_ARGS=(-var "sdk_platforms=[${list%,}]")
    fi
    build xcode -var xcode_xip_dir="$(dirname "$XIP")" -var xcode_xip_name="$(basename "$XIP")" \
      ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"}
    build agent
    ;;
  tools)
    : "${PKR_VAR_admin_password:?export PKR_VAR_admin_password first}"
    build agent
    ;;
  denials) show_denials ;;
  run|session)
    cmd="$1"; shift
    if [ "${1:-}" = --gui ]; then GUI=1; shift; fi
    if [ "$cmd" = run ]; then run_job "$@"; else run_session "$@"; fi
    ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
