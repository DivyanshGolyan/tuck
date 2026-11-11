#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
app="$PWD/build/Tuck.app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/Tuck "$app/Contents/MacOS/Tuck"
cp Info.plist "$app/Contents/Info.plist"
# Prefer a stable identity. Never silently fall back after a signing failure.
if [[ -n "${TUCK_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$TUCK_SIGN_IDENTITY" --identifier local.tuck "$app"
elif [[ -f "$HOME/.local/share/tuck/signing/identity.json" ]]; then
  python3 scripts/sign-local.py "$app"
else
  echo "Warning: ad-hoc development build; rebuilding may invalidate Accessibility approval." >&2
  codesign --force --sign - --identifier local.tuck "$app"
fi
codesign --verify --deep --strict "$app"
if [[ "${1:-}" == "--install" ]]; then
  dest="$HOME/Applications/Tuck.app"
  if pgrep -x Tuck >/dev/null; then
    echo "Quit Tuck before replacing its app bundle." >&2
    exit 1
  fi
  mkdir -p "$HOME/Applications"
  ditto "$app" "$dest"
  echo "$dest"
else
  echo "$app"
fi
