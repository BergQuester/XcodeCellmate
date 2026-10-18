#!/bin/bash
# ./agent.sh xcode <Xcode.xip>                       new Xcode: rebuild xcode-base, then agent-base
# ./agent.sh tools                                   new tools/rules: rebuild agent-base only
# ./agent.sh run [--gui] <repo> <prompt-file> [branch]    unattended job in a throwaway VM
# ./agent.sh session [--gui] <repo> [branch]              attended Claude Code session in a throwaway VM
#   --gui  show the VM's window (the agent user's desktop), e.g. to watch the Simulator
#
# Builds need:      PKR_VAR_admin_password   (admin password inside the VMs)
# Jobs & sessions:  ANTHROPIC_API_KEY, GH_TOKEN (fine-grained, READ-ONLY: this is what prevents pushes)
#
# Code in:  the starting branch's committed history, as a git bundle (uncommitted work stays behind).
# Code out: new commits on agent/<name>, fetched into your repo as a bundle. Uncommitted changes
#           left in the VM become a WIP commit (sessions ask first). This also happens on Ctrl-C.
set -euo pipefail
PKR="$(cd "$(dirname "$0")" && pwd)/agent.pkr.hcl"

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

OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=60)
GUI=0 KIND="" REPO="" BASE="" BRANCH="" OUT="" VM="" IP=""

rsh() { ssh "${OPTS[@]}" agent@"$IP" "$@"; }   # run a command in the VM as agent

# start_vm <job|session> <repo> [branch]: clone agent-base, boot it, copy the branch in.
start_vm() {
  KIND="$1"; REPO="$(cd "$2" && pwd)"
  BASE="${3:-$(git -C "$REPO" branch --show-current)}"
  : "${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY}"
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
  printf 'export ANTHROPIC_API_KEY=%q\nexport GH_TOKEN=%q\nexport TART_AGENT_VM=1\nexport AGENT_ATTENDED=%q\nexport AGENT_BASE_BRANCH=%q\nexport AGENT_BRANCH=%q\n' \
    "$ANTHROPIC_API_KEY" "$GH_TOKEN" "$([ "$KIND" = session ] && echo 1 || echo 0)" "$BASE" "$BRANCH" |
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
SETUP
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
    git -C "$REPO" fetch -q "$OUT/out.bundle" "$BRANCH:$BRANCH"
    echo; echo "Commits are on $BRANCH. Review: git -C \"$REPO\" log --stat $BASE..$BRANCH"
  else
    echo; echo "No new commits."
  fi
}

finish() {
  local rc=$?
  trap - EXIT INT TERM
  [ -n "$IP" ] && { collect || echo "Could not collect commits from the VM." >&2; }
  if [ -n "$VM" ]; then
    tart stop "$VM" >/dev/null 2>&1 || true
    tart delete "$VM" || true
  fi
  [ -n "$OUT" ] && echo "Logs and bundles: $OUT"
  exit "$rc"
}

run_job() {  # <repo> <prompt-file> [branch]
  [ -f "${2:-}" ] || { echo "Prompt file not found: ${2:-}" >&2; exit 1; }
  local prompt="$2"
  start_vm job "$1" "${3:-}"
  cp "$prompt" "$OUT/prompt.md"
  scp -q "${OPTS[@]}" "$OUT/prompt.md" agent@"$IP":
  rsh bash -l -s <<'REMOTE' 2>&1 | tee "$OUT/agent.log"
. ~/.job-env
cd ~/work
claude -p "$(cat ~/prompt.md)" --permission-mode auto || echo "claude exited with $?"
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
    XIP="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
    build xcode -var xcode_xip_dir="$(dirname "$XIP")" -var xcode_xip_name="$(basename "$XIP")"
    build agent
    ;;
  tools)
    : "${PKR_VAR_admin_password:?export PKR_VAR_admin_password first}"
    build agent
    ;;
  run|session)
    cmd="$1"; shift
    if [ "${1:-}" = --gui ]; then GUI=1; shift; fi
    if [ "$cmd" = run ]; then run_job "$@"; else run_session "$@"; fi
    ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac