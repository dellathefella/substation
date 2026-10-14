#!/bin/bash
# Builds Substation.app (menubar app + bundled daemon + web console + llama.cpp
# binaries) and packages it as a DMG. Ad-hoc signed for local distribution.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
VER=$(grep -o 'public static let version = "[^"]*"' daemon/Sources/substationd/api/Routes.swift | head -1 | cut -d'"' -f2)
[ -n "$VER" ] || { echo "cannot read version"; exit 1; }

APP="build/app/Substation.app"
BIN="$ROOT/daemon/.build/release/substationd"
MENU="menubar/.build/release/SubstationMenuBar"
LLAMA="third_party/llama.cpp/build/bin/llama-server"
RPC="third_party/llama.cpp/build/bin/ggml-rpc-server"

echo "==> building daemon"
(cd daemon && swift build -c release >/dev/null)
echo "==> building menubar"
(cd menubar && swift build -c release >/dev/null)
echo "==> building webui"
(cd webui && npm run build >/dev/null)

echo "==> staging $APP (v$VER)"
rm -rf build/app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Substation</string>
  <key>CFBundleDisplayName</key><string>Substation</string>
  <key>CFBundleIdentifier</key><string>ai.substation.app</string>
  <key>CFBundleExecutable</key><string>Substation</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Substation</string>
</dict>
</plist>
PLIST

cp "$MENU" "$APP/Contents/MacOS/Substation"
chmod +x "$APP/Contents/MacOS/Substation"
cp "$BIN" "$APP/Contents/Resources/substationd"
cp webui/src/../../assets/substation.svg "$APP/Contents/Resources/substation.svg" 2>/dev/null || true
mkdir -p "$APP/Contents/Resources/webui"
cp -R webui/dist/. "$APP/Contents/Resources/webui/"

echo "==> generating app icon from favicon"
ICONSET="$ROOT/build/AppIcon.iconset"
BASE_PNG="$ROOT/build/favicon-1024.png"
rm -rf "$ICONSET" "$BASE_PNG" "$ROOT/build/substation.svg.png"
mkdir -p "$ICONSET"
if qlmanage -t -s 1024 -o "$ROOT/build" "$ROOT/assets/substation.svg" >/dev/null 2>&1 && [ -f "$ROOT/build/substation.svg.png" ]; then
  mv "$ROOT/build/substation.svg.png" "$BASE_PNG"
  for sz in 16 32 128 256 512; do
    dbl=$((sz * 2))
    sips -z "$sz" "$sz" "$BASE_PNG" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1
    sips -z "$dbl" "$dbl" "$BASE_PNG" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1
  done
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    echo "    app icon: AppIcon.icns (from favicon)"
  else
    echo "    WARN: iconutil failed; app will use generic icon"
  fi
else
  echo "    WARN: could not render favicon via qlmanage; app will use generic icon"
fi

HAS_LLAMA=0
if [ -x "$ROOT/$LLAMA" ] && [ -x "$ROOT/$RPC" ]; then
  mkdir -p "$APP/Contents/Resources/bin"
  cp "$ROOT/$LLAMA" "$APP/Contents/Resources/bin/llama-server"
  cp "$ROOT/$RPC" "$APP/Contents/Resources/bin/ggml-rpc-server"
  HAS_LLAMA=1
fi

cat > "$APP/Contents/Resources/default-config.toml" <<'TOML'
# Substation default config (packaged app).
# $SUBSTATION_APP_RES is injected by the Substation menubar app.

[daemon]
bind = "127.0.0.1"
port = 8800

[engines]
base_port = 8940
triage_port = 8931
models_dir = "models"
llama_server = "$SUBSTATION_APP_RES/bin/llama-server"
rpc_server = "$SUBSTATION_APP_RES/bin/ggml-rpc-server"

[orchestrator]
enabled = true
triage_gguf = "models/triage.gguf"
cache_enabled = true

[orchestrator.tiers.fast]
desc = "Light & quick"
models = []

[orchestrator.tiers.balanced]
desc = "Balanced"
models = []

[orchestrator.tiers.smart]
desc = "Flagship"
models = []
TOML

echo "==> ad-hoc signing"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || codesign --force --deep --sign - "$APP"

echo "==> building DMG"
STAGE="build/dmg"
rm -rf "$STAGE" "build/Substation-$VER.dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# DMG volume icon — share the favicon on the mounted disk too.
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/$(printf 'Icon\r')"
  SetFile -a C "$STAGE" 2>/dev/null || true
fi
hdiutil create -volname "Substation $VER" -srcfolder "$STAGE" -ov -format UDZO "build/Substation-$VER.dmg" >/dev/null

echo
echo "done: build/Substation-$VER.dmg"
[ "$HAS_LLAMA" = "1" ] && echo "llama.cpp bundled" || echo "WARN: llama.cpp binaries not found — app will run without local engine support until llama-server is present"
echo "engines point at \$SUBSTATION_APP_RES/bin/"
