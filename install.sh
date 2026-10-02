#!/bin/bash
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || exit 0

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$HOME/Applications/Gremlin.app"
identity="Gremlin Code Signing"
keychain="$HOME/Library/Keychains/login.keychain-db"
domain="gui/$(id -u)"

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "gremlin: swiftc not found, run xcode-select --install" >&2
    exit 1
fi

build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

# Screen Recording grants follow the signing certificate, so a stable one keeps the grant across rebuilds.
if ! security find-identity -p codesigning "$keychain" | grep -q "\"$identity\""; then
    echo "Creating the \"$identity\" certificate in the login keychain..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$build/key.pem" -out "$build/cert.pem" -subj "/CN=$identity" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -addext "basicConstraints=critical,CA:false" 2>/dev/null
    openssl pkcs12 -export -inkey "$build/key.pem" -in "$build/cert.pem" \
        -name "$identity" -out "$build/identity.p12" -passout pass:gremlin
    security import "$build/identity.p12" -k "$keychain" -P gremlin -T /usr/bin/codesign >/dev/null
fi

echo "Building Gremlin..."
mkdir -p "$build/Gremlin.app/Contents/MacOS"
cp "$src/Info.plist" "$build/Gremlin.app/Contents/Info.plist"
xcrun swiftc -O "$src"/*.swift -o "$build/Gremlin.app/Contents/MacOS/gremlin"
codesign --force --keychain "$keychain" --sign "$identity" "$build/Gremlin.app"

pluck_agent="$HOME/Library/LaunchAgents/com.bunniesinc.pluck.plist"
if [[ -e "$pluck_agent" || -e "$HOME/Applications/Pluck.app" ]]; then
    echo "Removing Pluck, Gremlin replaces it..."
    launchctl bootout "$domain/com.bunniesinc.pluck" 2>/dev/null || true
    rm -rf "$HOME/Applications/Pluck.app" "$pluck_agent"
    pluck_removed=1
fi

echo "Installing to ${app/#$HOME/~}..."
pkill -x gremlin 2>/dev/null || true
while pgrep -x gremlin >/dev/null; do sleep 0.2; done
mkdir -p "$(dirname "$app")"
rm -rf "$app"
mv "$build/Gremlin.app" "$app"
open "$app"

echo "Gremlin is running in the menu bar"
if [[ -n "${pluck_removed:-}" ]]; then
    echo "Remove Pluck from System Settings > Privacy & Security > Screen Recording, and allow Gremlin when it asks"
fi
