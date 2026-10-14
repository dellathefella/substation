#!/usr/bin/env bash
#
# uninstall-daemon.sh — remove a deployed Substation daemon (controller or node).
#
# Intended for the head/worker Macs (e.g. run over SSH). It stops the daemon,
# removes any LaunchAgent, and removes the install tree (state, config, logs,
# models) unless --keep-data is passed.
#
# Daemons are matched by their working directory (so relative launches like
# `cd ~/substation-controller && ./bin/substationd --data ./state` are caught),
# and by role (a node runs with `--role node`; the controller runs without it).
#
# Usage:
#   ./scripts/uninstall-daemon.sh --role controller [options]
#   ./scripts/uninstall-daemon.sh --role node       [options]
#
# Options:
#   --role ROLE       controller | node   (required)
#   --prefix PATH     Install tree. Defaults:
#                       controller -> ~/substation-controller
#                       node       -> ~/substation-node
#   --keep-data       Keep the install tree. Only stop the daemon + LaunchAgent.
#   --force           Remove the install tree even if another Substation daemon is
#                     still running from it.
#   --dry-run         Print what would be done without touching anything.
#   --yes, -y         Do not ask for confirmation.
#   -h, --help        Show this help.
#
set -euo pipefail

ROLE=""
PREFIX=""
DRY_RUN=0
KEEP_DATA=0
FORCE=0
ASSUME_YES=0

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --role)      ROLE="${2:-}"; shift ;;
    --prefix)    PREFIX="${2:-}"; shift ;;
    --keep-data) KEEP_DATA=1 ;;
    --force)     FORCE=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -y|--yes)    ASSUME_YES=1 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

case "$ROLE" in
  controller) PREFIX="${PREFIX:-$HOME/substation-controller}" ;;
  node)       PREFIX="${PREFIX:-$HOME/substation-node}" ;;
  "")         echo "error: --role controller|node is required" >&2; usage; exit 2 ;;
  *)          echo "error: --role must be 'controller' or 'node'" >&2; exit 2 ;;
esac

# Resolve PREFIX to an absolute path (without requiring it to exist).
case "$PREFIX" in
  /*) : ;;
  *)  PREFIX="$PWD/$PREFIX" ;;
esac

LABELS=("com.substation.$ROLE" "ai.substation.$ROLE" "com.substation.daemon.$ROLE")

say() { printf '%s\n' "$*"; }
run() { if [ "$DRY_RUN" -eq 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }
rmd() { local p="$1"; if [ -e "$p" ] || [ -L "$p" ]; then run rm -rf "$p"; fi; }

# cwd of a pid (absolute), empty if unavailable
pid_cwd() {
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | awk '/^n/{sub(/^n/,""); print; exit}'
}
# full command line of a pid
pid_cmd() { ps -o command= -p "$1" 2>/dev/null || true; }

# PIDs of substationd whose cwd is this prefix and whose role matches $1
pids_for_role() {
  local role="$1" pid cwd cmd
  for pid in $(pgrep -x substationd 2>/dev/null || true); do
    cwd="$(pid_cwd "$pid")"
    case "$cwd" in
      "$PREFIX"|"$PREFIX"/*) : ;;
      *) continue ;;
    esac
    cmd="$(pid_cmd "$pid")"
    if [ "$role" = "node" ]; then
      case "$cmd" in *"--role node"*) printf '%s\n' "$pid" ;; esac
    else
      case "$cmd" in *"--role node"*) : ;; *) printf '%s\n' "$pid" ;; esac
    fi
  done
}

# Any substationd (any role) whose cwd is under the prefix
pids_any_under_prefix() {
  local pid cwd
  for pid in $(pgrep -x substationd 2>/dev/null || true); do
    cwd="$(pid_cwd "$pid")"
    case "$cwd" in
      "$PREFIX"|"$PREFIX"/*) printf '%s\n' "$pid" ;;
    esac
  done
}

say "Substation — $ROLE daemon uninstall"
say "  prefix: $PREFIX"
[ "$DRY_RUN" -eq 1 ] && say "(dry run — nothing will be changed)"
say ""

if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
  printf 'This will stop and remove the %s daemon at %s. Continue? [y/N] ' "$ROLE" "$PREFIX"
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) say "aborted."; exit 0 ;; esac
fi

# --- 1. stop the daemon via LaunchAgent (if one is loaded) -------------------
say "==> stopping LaunchAgent (if present)"
UID_NUM="$(id -u)"
for lbl in "${LABELS[@]}"; do
  launchctl bootout "gui/$UID_NUM/$lbl" >/dev/null 2>&1 || \
    launchctl remove "$lbl" >/dev/null 2>&1 || true
  rmd "$HOME/Library/LaunchAgents/$lbl.plist"
done

# --- 2. stop the daemon process (cwd + role match) --------------------------
say "==> stopping $ROLE daemon process"
TARGET_PIDS="$(pids_for_role "$ROLE" || true)"
if [ -n "$TARGET_PIDS" ]; then
  for pid in $TARGET_PIDS; do
    say "  stopping pid $pid: $(pid_cmd "$pid")"
    run kill "$pid"
  done
  sleep 2
  for pid in $TARGET_PIDS; do
    if kill -0 "$pid" 2>/dev/null; then
      say "  force-killing pid $pid"
      run kill -9 "$pid"
    fi
  done
else
  say "  (no $ROLE daemon found under $PREFIX)"
fi

# --- 3. remove the install tree ---------------------------------------------
if [ "$KEEP_DATA" -eq 1 ]; then
  say "==> keeping install tree: $PREFIX"
else
  if [ -d "$PREFIX" ]; then
    ALL_UNDER="$(pids_any_under_prefix || true)"
    REMAINING=""
    for pid in $ALL_UNDER; do
      case " $TARGET_PIDS " in *" $pid "*) : ;; *) REMAINING="$REMAINING $pid" ;; esac
    done
    if [ -n "$REMAINING" ] && [ "$FORCE" -ne 1 ]; then
      say "==> NOT removing install tree: other Substation daemon(s) still running from it:"
      for pid in $REMAINING; do say "      pid $pid: $(pid_cmd "$pid")"; done
      say "    Stop them too (run this script for the other role) or pass --force."
    else
      say "==> removing install tree: $PREFIX"
      rmd "$PREFIX"
    fi
  else
    say "==> install tree not found (nothing to remove)"
  fi
fi

say ""
if [ "$DRY_RUN" -eq 1 ]; then
  say "dry run complete — no changes made."
else
  say "$ROLE daemon uninstalled."
  [ "$KEEP_DATA" -eq 1 ] && say "Install tree kept at: $PREFIX"
fi
