#!/bin/bash
# Builds the macOS release: Release archive (arm64, hardened runtime) → signed app → DMG → notarized.
#
#   macos/packaging/make-dmg.sh
#
# Signing: with CODESIGN_IDENTITY="Developer ID Application: <name> (<TEAM>)" and DEVELOPMENT_TEAM=<TEAM>
# the app and the DMG get a Developer ID signature; without them an ad-hoc signature (runs on this Mac,
# Gatekeeper would refuse it elsewhere). Notarization: with NOTARY_PROFILE=<keychain profile of
# `xcrun notarytool store-credentials`> the DMG is notarized and stapled; otherwise that step is skipped.
# The version comes from windows/Directory.Build.props (the Windows release script sets it), the build
# number is the commit count. Output: macos/packaging/out/ClearStar-<version>-arm64.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(cd .. && pwd)
out=packaging/out
build=$out/build
mkdir -p "$out"

version=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$root/windows/Directory.Build.props" | head -1)
buildnum=$(git -C "$root" rev-list --count HEAD)
echo "ClearStar $version ($buildnum)"

identity=${CODESIGN_IDENTITY:--}
team=${DEVELOPMENT_TEAM:-}
xcodegen generate -q

rm -rf "$build"
xcodebuild -project ClearStar.xcodeproj -scheme ClearStar -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$build/ClearStar.xcarchive" -derivedDataPath "$build/dd" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$buildnum" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
  archive -quiet

app="$build/ClearStar.xcarchive/Products/Applications/ClearStar.app"
if [ "$identity" != "-" ]; then
  # A real identity: sign again with a secure timestamp (required by the notary service).
  codesign --force --deep --options runtime --timestamp --sign "$identity" "$app"
fi

echo "== signature"
codesign --verify --deep --strict --verbose=2 "$app"
flags=$(codesign -dv "$app" 2>&1 | sed -n 's/.*flags=\(0x[0-9a-f]*\)(\(.*\)).*/\2/p')
echo "flags: $flags"
case "$flags" in *runtime*) ;; *) echo "error: the app is not signed with the hardened runtime" >&2; exit 1 ;; esac
lipo -archs "$app/Contents/MacOS/ClearStar"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" -c "Print :LSMinimumSystemVersion" "$app/Contents/Info.plist"

echo "== dmg"
stage=$build/dmg
rm -rf "$stage"; mkdir -p "$stage"
ditto "$app" "$stage/ClearStar.app"
ln -s /Applications "$stage/Applications"
dmg="$out/ClearStar-$version-arm64.dmg"
rm -f "$dmg"
hdiutil create -volname "ClearStar $version" -srcfolder "$stage" -fs APFS -format UDZO -ov "$dmg" -quiet
if [ "$identity" != "-" ]; then codesign --force --timestamp --sign "$identity" "$dmg"; fi

# The image mounts and holds the app and the Applications link.
mnt=$(mktemp -d)
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" -quiet
test -d "$mnt/ClearStar.app" && test -L "$mnt/Applications"
codesign --verify --deep --strict "$mnt/ClearStar.app"
hdiutil detach "$mnt" -quiet

if [ -n "${NOTARY_PROFILE:-}" ] && [ "$identity" != "-" ]; then
  echo "== notarization"
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
else
  echo "notarization skipped (needs CODESIGN_IDENTITY, DEVELOPMENT_TEAM and NOTARY_PROFILE)"
fi
ls -lh "$dmg"
