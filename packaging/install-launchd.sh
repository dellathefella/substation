#!/bin/bash
# Install launchd jobs that SUPERVISE the substation daemons, replacing the manual
# `nohup … &` start. With launchd the controller / node agent:
#   • start at login (RunAtLoad) and survive reboots,
#   • are auto-restarted if they crash (KeepAlive),
#   • are stopped cleanly with `launchctl bootout` (which triggers the daemon's
#     SIGTERM child-cleanup, killing any llama-server it manages).
#
# Usage:
#   ./install-launchd.sh controller            # install/replace controller job
#   ./install-launchd.sh node                  # install/replace node job
#   ./install-launchd.sh both                  # both
#   ./install-launchd.sh controller --uninstall
#   ./install-launchd.sh both --uninstall
#
# Overridable env:
#   SUBSTATION_HOME   base dir holding the install (default: $HOME)
#   CONTROLLER_DIR    controller install dir (default: $SUBSTATION_HOME/substation-controller)
#   NODE_DIR          node agent install dir    (default: $SUBSTATION_HOME/substation-node)
#   CONTROLLER_BIN    controller binary       (default: $CONTROLLER_DIR/bin/substationd)
#   NODE_BIN          node agent binary       (default: $NODE_DIR/bin/substationd)
set -euo pipefail

LABEL_PREFIX="com.substation"
SUBSTATION_HOME="${SUBSTATION_HOME:-$HOME}"
CONTROLLER_DIR="${CONTROLLER_DIR:-$SUBSTATION_HOME/substation-controller}"
NODE_DIR="${NODE_DIR:-$SUBSTATION_HOME/substation-node}"
CONTROLLER_BIN="${CONTROLLER_BIN:-$CONTROLLER_DIR/bin/substationd}"
NODE_BIN="${NODE_BIN:-$NODE_DIR/bin/substationd}"
LA_AGENTS="$HOME/Library/LaunchAgents"

uninstall_role() {
  local role="$1" label="$LABEL_PREFIX.$role"
  local plist="$LA_AGENTS/$label.plist"
  local uid; uid="$(id -u)"
  echo "→ removing $label"
  launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  rm -f "$plist"
}

install_role() {
  local role="$1"
  local label="$LABEL_PREFIX.$role"
  local plist="$LA_AGENTS/$label.plist"
  local uid; uid="$(id -u)"

  local dir bin args workingdir
  if [ "$role" = "controller" ]; then
    dir="$CONTROLLER_DIR"; bin="$CONTROLLER_BIN"
    args="--config config/controller.toml --data ./state --webui ./webui"
    workingdir="$CONTROLLER_DIR"
  elif [ "$role" = "node" ]; then
    dir="$NODE_DIR"; bin="$NODE_BIN"
    args="--role node --config config/node.toml --data ./state"
    workingdir="$NODE_DIR"
  else
    echo "unknown role: $role" >&2; return 2
  fi

  if [ ! -x "$bin" ]; then
    echo "✗ binary not found or not executable: $bin" >&2
    echo "  (set ${role^^}_BIN or install the daemon first)" >&2
    return 1
  fi

  mkdir -p "$LA_AGENTS" "$workingdir/state/logs"

  # Build the <string>…</string> argv array from the space-separated args.
  local argv=""
  for a in $args; do argv="$argv        <string>$a</string>"$'\n'; done

  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$bin</string>
$argv  </array>
  <key>WorkingDirectory</key><string>$workingdir</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$workingdir/state/logs/$role.launchd.out.log</string>
  <key>StandardErrorPath</key><string>$workingdir/state/logs/$role.launchd.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLIST

  # Replace any running instance, then (re)load under the GUI domain.
  launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$uid" "$plist"
  launchctl kickstart -k "gui/$uid/$label" 2>/dev/null || true
  echo "✓ installed $label  (bin: $bin)"
  echo "  logs: $workingdir/state/logs/$role.launchd.{out,err}.log"
}

target="${1:-controller}"
mode="${2:-install}"

case "$target" in
  controller|node)
    if [ "$mode" = "--uninstall" ]; then uninstall_role "$target"; else install_role "$target"; fi
    ;;
  both)
    if [ "$mode" = "--uninstall" ]; then uninstall_role controller; uninstall_role node
    else install_role controller; install_role node; fi
    ;;
  *)
    echo "usage: $0 {controller|node|both} [--uninstall]" >&2
    exit 2
    ;;
esac

echo "done. Verify with:  launchctl print gui/$(id -u)/$LABEL_PREFIX.$target"
