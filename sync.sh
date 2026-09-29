#!/usr/bin/env bash
# Sync this repo to a cluster. The local repo is the source of truth:
# never edit files on the remote copy — they will be overwritten.
#
# Usage:
#   ./sync.sh              # -> sc  (default)
#   ./sync.sh sc           # -> sc  (/nlp/scr/ljbailey/projects/<repo>)
#   ./sync.sh marlowe      # -> sc, THEN sc -> marlowe (/scratch/m000123-pm06/ljbailey/projects/<repo>)
#
# Override defaults via env vars:
#   REMOTE_HOST=john10 REMOTE_DIR=/nlp/scr/... ./sync.sh
#   MARLOWE_HOP=john10 MARLOWE_DIR=/scratch/... ./sync.sh marlowe
#
# Why marlowe is two-stage: marlowe requires Duo 2FA, and the only way in without
# a push is the ssh ControlMaster socket that lives ON THE JOHN MACHINE (see the
# Marlowe section of CLAUDE.md). A direct `rsync -e "ssh -J john10" marlowe-login:...`
# from the laptop does NOT reuse that socket — `-J` only tunnels, so the laptop
# still does its own handshake with marlowe and triggers a Duo push. Hence: push
# to sc first, then have the john machine push that copy onward over the multiplexed hop.
set -euo pipefail

TARGET="sc"
case "${1:-}" in
  sc|marlowe) TARGET="$1"; shift ;;
  "")         ;;
  *)          echo "sync.sh: unknown target '$1' (expected: sc | marlowe)" >&2; exit 2 ;;
esac

# stanford-scdt is the data-transfer flavor of the login node — use it for
# rsync; run compute commands on the john machine instead.
REMOTE_HOST="${REMOTE_HOST:-stanford-scdt}"
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="$(basename "$LOCAL_DIR")"
REMOTE_DIR="${REMOTE_DIR:-/nlp/scr/ljbailey/projects/$PROJECT_NAME}"

# marlowe: reached only via the john machine's ControlMaster (Duo-free hop).
# The mirror lives on the pm06 SCRATCH allocation: /projects/m000123 is full and
# /scratch/m000123 is over its inode quota. Scratch is NOT backed up — archive
# finished runs to sc.
MARLOWE_HOP="${MARLOWE_HOP:-john10}"
MARLOWE_HOST="${MARLOWE_HOST:-marlowe-login}"
MARLOWE_DIR="${MARLOWE_DIR:-/scratch/m000123-pm06/ljbailey/projects/$PROJECT_NAME}"

# Excluded dirs are also protected from --delete on the remote side, so job
# outputs written there survive re-syncs. Keep this list aligned with the
# run-output patterns in .gitignore — anything a run generates lives only on
# the remote, so if it is NOT excluded here, --delete will destroy it.
EXCLUDES=(
  --exclude '.git/'
  --exclude '.claude/'
  --exclude '.venv/'
  --exclude '__pycache__/'
  --exclude '*.egg-info/'
  --exclude '*.pyc'
  --exclude '.DS_Store'
  --exclude 'experiments/*/out/'
  --exclude 'outputs/'
  --exclude 'results/'
  --exclude 'data/'
  --exclude 'checkpoints/'
  --exclude 'wandb/'
  --exclude 'slurm_logs/'
)

# --- preflight: for marlowe, fail loudly BEFORE stage 1 if the hop is dead ----
if [ "$TARGET" = "marlowe" ]; then
  if ! ssh -o BatchMode=yes "$MARLOWE_HOP" "ssh -O check $MARLOWE_HOST" >/dev/null 2>&1; then
    cat >&2 <<MSG
sync.sh: no live ssh ControlMaster for '$MARLOWE_HOST' on '$MARLOWE_HOP'.

Without it every marlowe connection needs a Duo push, so this is refused rather
than left to hang. To re-establish (see CLAUDE.md > Marlowe):
  1. ssh stanford-sc, attach/open the long-lived tmux session
  2. inside it: ssh $MARLOWE_HOP  then  ssh $MARLOWE_HOST   (approve the Duo push)
  3. leave that tmux window open; ControlPersist keeps the socket alive 12h
MSG
    exit 1
  fi
fi

ssh "$REMOTE_HOST" "mkdir -p '$REMOTE_DIR'"

# Stamp the sync with local git state so remote experiment runs can record
# exactly what code they ran (the remote copy has no .git).
{
  echo "commit: $(git -C "$LOCAL_DIR" rev-parse --verify -q HEAD 2>/dev/null || echo unknown)"
  echo "dirty: $([ -n "$(git -C "$LOCAL_DIR" status --porcelain 2>/dev/null)" ] && echo true || echo false)"
  echo "synced_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$LOCAL_DIR/.sync_meta"

# --- stage 1: laptop -> sc (always) ------------------------------------------
rsync -azv --delete "${EXCLUDES[@]}" "$LOCAL_DIR/" "$REMOTE_HOST:$REMOTE_DIR/"
echo "Synced $PROJECT_NAME -> $REMOTE_HOST:$REMOTE_DIR"

[ "$TARGET" = "marlowe" ] || exit 0

# --- stage 2: sc -> marlowe, run FROM the hop so the ControlMaster is used ----
# Re-quote the exclude list for the remote shell (it crosses two levels of ssh).
EX_STR=""
for e in "${EXCLUDES[@]}"; do EX_STR+=" $(printf '%q' "$e")"; done

ssh "$MARLOWE_HOP" "ssh $MARLOWE_HOST 'mkdir -p \"$MARLOWE_DIR\"'"
ssh "$MARLOWE_HOP" "rsync -az --delete$EX_STR '$REMOTE_DIR/' '$MARLOWE_HOST:$MARLOWE_DIR/'"
echo "Synced $PROJECT_NAME -> $MARLOWE_HOST:$MARLOWE_DIR (via $MARLOWE_HOP)"
