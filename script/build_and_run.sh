#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
support="$HOME/Library/Application Support/Gemini Desktop Bridge"
app="$HOME/Applications/Gemini Desktop Bridge.app"
mkdir -p "$HOME/Applications"
mkdir -p -m 700 "$support"

# Avoid changing the ad hoc signature on reinstall when the helper source is unchanged.
icon="$project/assets/GeminiDesktopBridge.png"
fingerprint="$(/usr/bin/shasum -a 256 "$project/bridge/GeminiDesktopBridge.swift" \
  "$project/bridge/Info.plist" "$icon" | /usr/bin/awk '{print $1}')"
if [[ ! -x "$app/Contents/MacOS/GeminiDesktopBridge" ]] ||
   [[ ! -f "$support/helper-source.sha256" ]] ||
   [[ "$(<"$support/helper-source.sha256")" != "$fingerprint" ]]; then
  build="$(/usr/bin/mktemp -d "$HOME/Applications/.gemini-bridge.XXXXXX")"
  staged="$build/Gemini Desktop Bridge.app"
  mkdir -p "$staged/Contents/MacOS" "$staged/Contents/Resources" "$build/AppIcon.iconset"
  for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$icon" --out "$build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    /usr/bin/sips -z "$retina" "$retina" "$icon" --out "$build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  /usr/bin/iconutil -c icns "$build/AppIcon.iconset" -o "$staged/Contents/Resources/GeminiDesktopBridge.icns"
  cp "$project/bridge/Info.plist" "$staged/Contents/Info.plist"
  /usr/bin/swiftc -O -warnings-as-errors "$project/bridge/GeminiDesktopBridge.swift" \
    -o "$staged/Contents/MacOS/GeminiDesktopBridge"
  /usr/bin/codesign --force --sign - "$staged"
  /usr/bin/codesign --verify --strict "$staged"
  if [[ -d "$app" ]]; then
    mv "$app" "$build/previous.app"
  fi
  if ! mv "$staged" "$app"; then
    if [[ -d "$build/previous.app" ]]; then mv "$build/previous.app" "$app"; fi
    exit 1
  fi
  # Remove only the private staging tree created by this invocation.
  /usr/bin/python3 -c 'import sys, shutil; shutil.rmtree(sys.argv[1])' "$build"
  printf '%s\n' "$fingerprint" > "$support/helper-source.sha256"
fi

/usr/bin/install -m 600 "$project/bridge/server.py" "$support/server.py.new"
mv "$support/server.py.new" "$support/server.py"
if [[ "${1:-}" == "--request-access" ]]; then
  /usr/bin/open -g -n "$app"
fi
printf 'Installed %s\n' "$app" "$support/server.py"
