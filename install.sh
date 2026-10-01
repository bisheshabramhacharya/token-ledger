#!/bin/sh
# Installs or updates Token Ledger and opens it.
#   curl -fsSL https://raw.githubusercontent.com/bisheshabramhacharya/token-ledger/main/install.sh | sh
set -e
url=https://github.com/bisheshabramhacharya/token-ledger/releases/latest/download/TokenLedger.zip

# Update an existing copy in place; otherwise prefer /Applications.
if [ -d "$HOME/Applications/TokenLedger.app" ]; then
  dest="$HOME/Applications"
elif [ -d /Applications/TokenLedger.app ] || [ -w /Applications ]; then
  dest=/Applications
else
  dest="$HOME/Applications"
fi
mkdir -p "$dest"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Token Ledger..."
curl -fsSL "$url" -o "$tmp/TokenLedger.zip"
ditto -x -k "$tmp/TokenLedger.zip" "$tmp"

pkill -x TokenLedger 2>/dev/null && sleep 1 || true
rm -rf "$dest/TokenLedger.app"
mv "$tmp/TokenLedger.app" "$dest/"
xattr -dr com.apple.quarantine "$dest/TokenLedger.app" 2>/dev/null || true
open "$dest/TokenLedger.app"
echo "Installed $dest/TokenLedger.app. Look for the chart icon in your menu bar."
