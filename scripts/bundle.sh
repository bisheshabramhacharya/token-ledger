#!/bin/sh
# Builds TokenLedger.app (menu bar only, no Dock icon) and installs it to ~/Applications.
set -e
cd "$(dirname "$0")/.."
swift build -c release
app=build/TokenLedger.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp .build/release/TokenLedger "$app/Contents/MacOS/TokenLedger"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.bishesha.tokenledger</string>
  <key>CFBundleName</key><string>Token Ledger</string>
  <key>CFBundleExecutable</key><string>TokenLedger</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
mkdir -p ~/Applications
rm -rf ~/Applications/TokenLedger.app
cp -R "$app" ~/Applications/
echo "Installed ~/Applications/TokenLedger.app"
