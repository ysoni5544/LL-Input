#!/bin/bash
# Builds "LL Input.app" into ./dist
set -e

BIN="AudioPassthrough"          # SwiftPM target / executable name (internal)
APP_NAME="LL Input"             # user-facing app name
BUNDLE="dist/${APP_NAME}.app"

echo "Building release binary..."
swift build -c release

echo "Assembling app bundle..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

# Keep the executable named to match CFBundleExecutable in Info.plist.
cp ".build/release/${BIN}" "$BUNDLE/Contents/MacOS/${BIN}"
cp Info.plist "$BUNDLE/Contents/Info.plist"

# Copy menu-bar icon assets (plug on/off, template PNGs @1x/@2x/@4x).
if [ -d Resources ]; then
  cp Resources/plug_on*.png Resources/plug_off*.png "$BUNDLE/Contents/Resources/" 2>/dev/null || true
fi

# Build the app icon (.icns) from the iconset, if present.
if [ -d Resources/AppIcon.iconset ]; then
  if command -v iconutil >/dev/null 2>&1; then
    iconutil -c icns Resources/AppIcon.iconset -o "$BUNDLE/Contents/Resources/AppIcon.icns"
    echo "App icon built."
  else
    echo "warning: iconutil not found; app icon skipped."
  fi
fi

# Ad-hoc sign so mic permission + entitlements work locally.
codesign --force --deep --sign - \
  --entitlements <(cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
EOF
) "$BUNDLE" 2>/dev/null || codesign --force --deep --sign - "$BUNDLE"

echo "Done: $BUNDLE"
echo "Run with: open \"$BUNDLE\"   (or)   \"$BUNDLE/Contents/MacOS/${BIN}\""
