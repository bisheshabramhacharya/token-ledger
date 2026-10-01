#!/bin/sh
# Builds TokenLedger.app (menu bar only, no Dock icon).
#   scripts/bundle.sh            build for this Mac and install to ~/Applications
#   scripts/bundle.sh --release  build a universal (Apple Silicon + Intel) app and zip it in build/
set -e
cd "$(dirname "$0")/.."
VERSION=1.0.0
app=build/TokenLedger.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

if [ "$1" = "--release" ]; then
  swift build -c release --triple arm64-apple-macosx14.0
  swift build -c release --triple x86_64-apple-macosx14.0
  lipo -create -output "$app/Contents/MacOS/TokenLedger" \
    .build/arm64-apple-macosx/release/TokenLedger .build/x86_64-apple-macosx/release/TokenLedger
else
  swift build -c release
  cp .build/release/TokenLedger "$app/Contents/MacOS/TokenLedger"
fi

strip -x "$app/Contents/MacOS/TokenLedger"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.bishesha.tokenledger</string>
  <key>CFBundleName</key><string>Token Ledger</string>
  <key>CFBundleDisplayName</key><string>Token Ledger</string>
  <key>CFBundleExecutable</key><string>TokenLedger</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"

if [ "$1" = "--release" ]; then
  rm -f build/TokenLedger.zip
  ditto -c -k --keepParent "$app" build/TokenLedger.zip
  echo "Built build/TokenLedger.zip ($(lipo -archs "$app/Contents/MacOS/TokenLedger"))"
else
  mkdir -p ~/Applications
  rm -rf ~/Applications/TokenLedger.app
  cp -R "$app" ~/Applications/
  echo "Installed ~/Applications/TokenLedger.app"
fi
