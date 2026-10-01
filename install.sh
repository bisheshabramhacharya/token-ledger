#!/bin/sh
# Installs the latest Token Ledger release into /Applications and opens it.
#   curl -fsSL https://raw.githubusercontent.com/bisheshabramhacharya/token-ledger/main/install.sh | sh
set -e
url=https://github.com/bisheshabramhacharya/token-ledger/releases/latest/download/TokenLedger.zip
dest=/Applications
[ -w "$dest" ] || dest="$HOME/Applications"
mkdir -p "$dest"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Token Ledger..."
curl -fsSL "$url" -o "$tmp/TokenLedger.zip"
ditto -x -k "$tmp/TokenLedger.zip" "$tmp"

pkill -x TokenLedger 2>/dev/null || true
rm -rf "$dest/TokenLedger.app"
mv "$tmp/TokenLedger.app" "$dest/"
xattr -dr com.apple.quarantine "$dest/TokenLedger.app" 2>/dev/null || true
open "$dest/TokenLedger.app"
echo "Installed to $dest/TokenLedger.app. Look for the icon in your menu bar."
