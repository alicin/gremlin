#!/bin/bash
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || exit 0

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
label="com.bunniesinc.pluck"
app="$HOME/Applications/Pluck.app"
agent="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "pluck: swiftc not found, run xcode-select --install" >&2
    exit 1
fi

build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

echo "Building Pluck..."
mkdir -p "$build/Pluck.app/Contents/MacOS"
cp "$src/Info.plist" "$build/Pluck.app/Contents/Info.plist"
xcrun swiftc -O "$src/main.swift" -o "$build/Pluck.app/Contents/MacOS/pluck"
codesign --force --sign - "$build/Pluck.app"

echo "Installing to ${app/#$HOME/~}..."
launchctl bootout "$domain/$label" 2>/dev/null || true
mkdir -p "$(dirname "$app")" "$(dirname "$agent")"
rm -rf "$app"
mv "$build/Pluck.app" "$app"

cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$app/Contents/MacOS/pluck</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

launchctl bootstrap "$domain" "$agent"
echo "Pluck is running: cmd+shift+1 copies text, cmd+shift+2 copies a color"
