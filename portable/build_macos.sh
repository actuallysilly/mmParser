#!/usr/bin/env bash
#
# build_macos.sh — produce MMA.dmg on a Mac.
#
#     ./build_macos.sh
#
# MUST run on macOS. PyInstaller cannot cross-compile: a Windows machine
# cannot produce a .app, and there is no flag that changes that. If you only
# have a Windows box, run this on a macOS CI runner instead.
#
# Output: dist/MMA.dmg — drag-to-Applications, with the install guide inside.

set -euo pipefail

APP_NAME="MMA"
VOL_NAME="MMA Installer"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "ERROR: this must run on macOS. PyInstaller cannot cross-compile." >&2
  exit 1
fi

echo "==> checking tools"
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
python3 -c "import PyInstaller" 2>/dev/null || {
  echo "PyInstaller missing:  python3 -m pip install pyinstaller" >&2; exit 1; }
python3 -c "import pynput" 2>/dev/null || {
  echo "pynput missing:  python3 -m pip install pynput" >&2; exit 1; }

echo "==> tests (a broken build is worse than no build)"
python3 -m unittest discover -q

echo "==> cleaning"
rm -rf build dist

echo "==> freezing"
python3 -m PyInstaller mma.spec --noconfirm

APP="dist/${APP_NAME}.app"
[[ -d "$APP" ]] || { echo "ERROR: $APP was not produced" >&2; exit 1; }

# Ad-hoc signature. This does NOT stop Gatekeeper's "unidentified developer"
# warning - only paid notarisation does that. It matters for a different
# reason: macOS keys granted permissions to a binary's signature, and an
# UNSIGNED binary gets a fresh identity on every rebuild, so the user has to
# re-grant Input Monitoring and Accessibility after each update. Ad-hoc
# signing makes that stable.
echo "==> signing (ad-hoc)"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP" || echo "WARNING: signature did not verify"

echo "==> staging dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/docs"
cp docs/install-macos.html "$STAGE/docs/"
# Named so it is the obvious thing to click before dragging the app across.
ln -s "docs/install-macos.html" "$STAGE/READ ME FIRST.html"

echo "==> building dmg"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "dist/${APP_NAME}.dmg" >/dev/null
rm -rf "$STAGE"

echo
echo "Built: dist/${APP_NAME}.dmg"
echo
echo "The recipient WILL be stopped by Gatekeeper on first open - that is"
echo "expected for an unsigned app and docs/install-macos.html walks them"
echo "through it. To remove that warning entirely you need a paid Apple"
echo "Developer account (\$99/yr) plus notarisation; nothing in this script"
echo "can substitute for it."
