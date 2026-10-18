#!/bin/bash
# ./agent.sh xcode <Xcode.xip>                    new Xcode: rebuild xcode-base, then agent-base
# ./agent.sh tools                                new tools (brew_packages): rebuild agent-base only
# ./agent.sh run <repo> <prompt-file> [branch]    run a job in a throwaway VM
#
# Builds need:  PKR_VAR_admin_password   (admin password inside the VMs)
# Jobs need:    ANTHROPIC_API_KEY, GH_TOKEN (fine-grained, READ-ONLY: this is what prevents pushes)
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

# ---------- jobs ----------

run_job() {
  local REPO PROMPT_FILE BASE JOB BRANCH OUT ORIGIN IP
  REPO="$(cd "$1" && pwd)"; PROMPT_FILE="$2"
  BASE="${3:-$(git -C "$REPO" branch --show-current)}"
  : "${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY}"
  : "${GH_TOKEN:?set GH_TOKEN (read-only fine-grained token)}"

  JOB="job-$(date +%Y%m%d-%H%M%S)"; BRANCH="agent/$JOB"
  OUT="$HOME/agent-jobs/$JOB"; mkdir -p "$OUT"
  ORIGIN="$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -E 's#^git@github\.com:#https://github.com/#' || true)"

  git -C "$REPO" bundle create "$OUT/in.bundle" "$BASE"
  cp "$PROMPT_FILE" "$OUT/prompt.md"

  tart clone agent-base "$JOB"
  trap "tart stop '$JOB' >/dev/null 2>&1 || true; tart delete '$JOB' || true" EXIT
  tart run --no-graphics --net-softnet "$JOB" >"$OUT/tart.log" 2>&1 &

  local OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=60)
  until IP=$(tart ip "$JOB" 2>/dev/null); do sleep 2; done
  until ssh "${OPTS[@]}" agent@"$IP" true 2>/dev/null; do sleep 2; done

  scp "${OPTS[@]}" "$OUT/in.bundle" "$OUT/prompt.md" agent@"$IP":
  printf 'export ANTHROPIC_API_KEY=%q\nexport GH_TOKEN=%q\n' "$ANTHROPIC_API_KEY" "$GH_TOKEN" |
    ssh "${OPTS[@]}" agent@"$IP" 'umask 077; cat > ~/.job-env'

  ssh "${OPTS[@]}" agent@"$IP" bash -l -s -- "$BASE" "$BRANCH" "$ORIGIN" <<'REMOTE' 2>&1 | tee "$OUT/agent.log"
set -e
. ~/.job-env
git clone -q -b "$1" ~/in.bundle ~/work && cd ~/work
git switch -q -c "$2"
git remote remove origin
if [ -n "$3" ]; then
  git remote add origin "$3"                       # fetch-only, via the read-only token
  git remote set-url --push origin PUSH-DISABLED
fi
claude -p "$(cat ~/prompt.md)" --dangerously-skip-permissions || echo "claude exited with $?"
git bundle create ~/out.bundle "$1..$2" 2>/dev/null || echo "No new commits."
REMOTE

  if scp "${OPTS[@]}" agent@"$IP":out.bundle "$OUT/" 2>/dev/null; then
    git -C "$REPO" fetch -q "$OUT/out.bundle" "$BRANCH:$BRANCH"
    echo; echo "Commits are on $BRANCH. Review: git -C \"$REPO\" log --stat $BASE..$BRANCH"
  fi
  echo "Logs and bundles: $OUT"
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
  run) shift; run_job "$@" ;;
  *) sed -n '2,4p' "$0"; exit 1 ;;
esac
