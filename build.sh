#!/bin/zsh
# Builds Tidal.app (interface + embedded agent) and optionally installs it.
#   ./build.sh            build into ./build
#   ./build.sh install    build, then copy to /Applications (or $TIDAL_DEST)
# Set DEVELOPER_DIR to pick a specific Xcode, e.g. DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./build.sh
set -euo pipefail
cd "${0:A:h}"

SWIFTC=(/usr/bin/xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx27.0 -parse-as-library)

OUT=build
APP=$OUT/Tidal.app
AGENT=$APP/Contents/Library/LoginItems/TidalAgent.app
rm -rf $APP
mkdir -p $APP/Contents/{MacOS,Resources} $AGENT/Contents/{MacOS,Resources}

echo "› agent"
$SWIFTC -o $AGENT/Contents/MacOS/TidalAgent Shared/*.swift Design/*.swift Agent/*.swift
echo "› interface"
$SWIFTC -o $APP/Contents/MacOS/Tidal Shared/*.swift Design/*.swift App/*.swift

cp Resources/catalog.json $APP/Contents/Resources/
cp Resources/0vyx-logo.png $APP/Contents/Resources/
cp Resources/catalog.json $AGENT/Contents/Resources/
cp Resources/Info.plist $APP/Contents/Info.plist
cp Resources/Agent-Info.plist $AGENT/Contents/Info.plist

echo "› icon"
if [[ -d Resources/AppIcon.icon ]] && /usr/bin/xcrun --find actool >/dev/null 2>&1; then
  /usr/bin/xcrun actool Resources/AppIcon.icon --compile $APP/Contents/Resources --app-icon AppIcon \
    --platform macosx --minimum-deployment-target 27.0 --output-partial-info-plist $OUT/icon-partial.plist \
    --enable-on-demand-resources NO >/dev/null 2>&1 || echo "  actool failed; using icns only"
fi
[[ -f $APP/Contents/Resources/AppIcon.icns ]] && cp $APP/Contents/Resources/AppIcon.icns $AGENT/Contents/Resources/
[[ -f $APP/Contents/Resources/Assets.car ]] && cp $APP/Contents/Resources/Assets.car $AGENT/Contents/Resources/

echo "› sign (ad-hoc, hardened runtime)"
codesign --force --sign - --identifier app.tidal.mac.agent $AGENT
codesign --force --options runtime --sign - --identifier app.tidal.mac $APP
codesign --verify --strict $APP && echo "  signature ok"

if [[ "${1:-}" == "install" ]]; then
  DEST=${TIDAL_DEST:-/Applications}
  [[ -d $DEST ]] || { echo "destination not found"; exit 1; }
  pkill -f "Tidal.app/Contents/MacOS/Tidal" 2>/dev/null || true
  rm -rf $DEST/Tidal.app
  ditto $APP $DEST/Tidal.app
  echo "› installed to $DEST/Tidal.app"
  # Restart the background agent so the new build takes over.
  if launchctl print gui/$UID/app.tidal.mac.agent.launcher >/dev/null 2>&1; then
    launchctl kickstart -k gui/$UID/app.tidal.mac.agent.launcher && echo "› agent restarted"
  else
    pkill -f "TidalAgent.app/Contents/MacOS/TidalAgent" 2>/dev/null || true
  fi
fi
