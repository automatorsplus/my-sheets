#!/bin/zsh
# Builds build/MySheets.app with the Command Line Tools' swiftc. No Xcode project.
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID=local.mysheets
APP=build/MySheets.app

# iCloud-synced folders such as the Desktop keep adding Finder attributes to bundles, and
# codesign refuses those. So the app is put together and signed in a temporary folder, then copied in.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STAGED=$WORK/MySheets.app
mkdir -p "$STAGED/Contents/MacOS" "$STAGED/Contents/Resources" build
cp Info.plist "$STAGED/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$STAGED/Contents/Resources/"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  Sources/*.swift \
  -o "$STAGED/Contents/MacOS/MySheets"

xattr -cr "$STAGED"
codesign --force --sign - --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" "$STAGED"

rm -rf "$APP"
ditto "$STAGED" "$APP"
# Tell Launch Services about the new build, so Finder's Open With lists it for .xlsx files.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo "Built $PWD/$APP"
