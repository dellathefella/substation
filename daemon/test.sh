#!/bin/bash
# Run the daemon test suite.
#
# Command Line Tools-only installs don't ship XCTest, so `swift test` fails with
# "no such module 'XCTest'". If a full Xcode is present we point DEVELOPER_DIR at
# it for this command only (no global xcode-select change). Override by exporting
# DEVELOPER_DIR yourself.
set -euo pipefail
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
cd "$(dirname "$0")"
exec swift test "$@"
