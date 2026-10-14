#!/usr/bin/env bash
#
# uninstall-app.sh — remove the Substation macOS app and everything it installed.
#
# Cleans up:
#   • the running menu-bar app + the bundled substationd daemon it supervises
#   • the LaunchAgent (com.substation.menubar)
#   • UserDefaults / preferences (ai.substation.app)
#   • caches, saved state, logs
#   • the app bundle in /Applications (or ~/Applications)
#   • app data in ~/Library/Application Support/Substation  (unless --keep-data)
#
# Usage:
#   ./scripts/uninstall-app.sh [options]
#
# Options:
#   --keep-data     Keep ~/Library/Application Support/Substation (state, models,
#                   logs, config.toml). Everything else is still removed.
#   --keep-app      Keep the .app bundle (stop + clean support files only).
#   --app-path PATH Override where Substation.app lives.
#   --dry-run       Print what would be removed without touching anything.
#   --yes, -y       Do not ask for confirmation.
#   -h, --help      Show this help.
#
set -euo pipefail

BUNDLE_ID="ai.substation.app"
LAUNCH_LABEL="com.substation.menubar"
SUPPORT_DIR="$HOME/Library/Application Support/Substation"

DRY_RUN=0
KEEP_DATA=0
KEEP_APP=0
ASSUME_YES=0
APP_PATH=""

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --keep-data) KEEP_DATA=1 ;;
    --keep-app)  KEEP_APP=1 ;;
    --app-path)  APP_PATH="${2:-}"; shift ;;
    --dry-run)   DRY_RUN=1 ;;
    -y|--yes)    ASSUME_YES=1 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

say()  { printf '%s\n' "$*"; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }
rmf()  { # rm -f, tolerant
  local p="$1"
  if [ -e "$p" ] || [ -L "$p" ]; then run rm -f "$p"; fi
}
rmd()  { # rm -rf, tolerant
  local p="$1"
  if [ -e "$p" ] || [ -L "$p" ]; then run rm -rf "$p"; fi
}

# --- locate the app bundle -----------------------------------------------------
find_app() {
  if [ -n "$APP_PATH" ]; then
    [ -d "$APP_PATH" ] && { printf '%s\n' "$APP_PATH"; return 0; }
    return 1
  fi
  for c in "/Applications/Substation.app" "$HOME/Applications/Substation.app"; do
    [ -d "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}
APP="$(find_app || true)"

say "Substation — app uninstall"
[ "$DRY_RUN" -eq 1 ] && say "(dry run — nothing will be changed)"
say ""

# --- confirmation ------------------------------------------------------------
if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
  printf 'This will remove the Substation app and its files. Continue? [y/N] '
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) say "aborted."; exit 0 ;; esac
fi

# --- 1. stop the menu-bar app ------------------------------------------------
say "==> stopping menu-bar app"
osascript -e 'tell application "Substation" to quit' >/dev/null 2>&1 || true
pkill -x "Substation" 2>/dev/null || true

# --- 2. stop the bundled daemon (only the one owned by the app) --------------
say "==> stopping bundled daemon"
if [ -n "$APP" ]; then
  # match the daemon launched from inside the app bundle
  pkill -f "$APP/Contents/Resources/substationd" 2>/dev/null || true
fi
# also match any daemon pointed at the app's support dir
pkill -f "Application Support/Substation" 2>/dev/null || true
sleep 1
# force anything still alive
pkill -9 -f "Application Support/Substation" 2>/dev/null || true

# --- 3. remove the LaunchAgent ----------------------------------------------
say "==> removing LaunchAgent ($LAUNCH_LABEL)"
launchctl bootout "gui/$(id -u)/$LAUNCH_LABEL" >/dev/null 2>&1 || \
  launchctl remove "$LAUNCH_LABEL" >/dev/null 2>&1 || true
rmf "$HOME/Library/LaunchAgents/$LAUNCH_LABEL.plist"

# --- 4. clear UserDefaults / preferences ------------------------------------
say "==> clearing preferences ($BUNDLE_ID)"
run defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
rmf "$HOME/Library/Preferences/$BUNDLE_ID.plist"
rmd "$HOME/Library/Preferences/ByHost/$BUNDLE_ID"*.plist 2>/dev/null || true

# --- 5. caches, saved state, logs -------------------------------------------
say "==> clearing caches / saved state / logs"
rmd "$HOME/Library/Caches/$BUNDLE_ID"
rmd "$HOME/Library/HTTPStorages/$BUNDLE_ID"
rmd "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
rmd "$HOME/Library/Logs/Substation"

# --- 6. app data ------------------------------------------------------------
if [ "$KEEP_DATA" -eq 1 ]; then
  say "==> keeping app data: $SUPPORT_DIR"
else
  say "==> removing app data: $SUPPORT_DIR"
  rmd "$SUPPORT_DIR"
fi

# --- 7. the app bundle ------------------------------------------------------
if [ "$KEEP_APP" -eq 1 ]; then
  say "==> keeping app bundle"
elif [ -n "$APP" ]; then
  say "==> removing app bundle: $APP"
  rmd "$APP"
else
  say "==> app bundle not found (nothing to remove)"
fi

say ""
if [ "$DRY_RUN" -eq 1 ]; then
  say "dry run complete — no changes made."
else
  say "Substation app uninstalled."
  [ "$KEEP_DATA" -eq 1 ] && say "Your models/state were kept in: $SUPPORT_DIR"
fi
