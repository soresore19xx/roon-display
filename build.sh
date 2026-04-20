#!/bin/sh
set -e
cd "$(dirname "$0")"

echo "Building RoonDisplay (universal binary)..."
swiftc RoonDisplay.swift -o RoonDisplay_arm64 -framework Cocoa -framework WebKit \
    -target arm64-apple-macos11
swiftc RoonDisplay.swift -o RoonDisplay_x86_64 -framework Cocoa -framework WebKit \
    -target x86_64-apple-macos10.15
lipo -create -output RoonDisplay RoonDisplay_arm64 RoonDisplay_x86_64
rm RoonDisplay_arm64 RoonDisplay_x86_64

APP=RoonDisplay.app
mkdir -p "${APP}/Contents/MacOS"
cp RoonDisplay "${APP}/Contents/MacOS/"

cat > "${APP}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>RoonDisplay</string>
    <key>CFBundleIdentifier</key>
    <string>com.hogehoge.roon-display</string>
    <key>CFBundleName</key>
    <string>RoonDisplay</string>
    <key>CFBundleDisplayName</key>
    <string>Roon Display</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

echo "Done: ${APP}"

echo "Installing to /Applications..."
cp -R "${APP}" /Applications/
xattr -d com.apple.quarantine /Applications/RoonDisplay.app 2>/dev/null || true
echo "Installed: /Applications/RoonDisplay.app"

echo "Creating DMG..."
TMPDIR=$(mktemp -d)
cp -R "${APP}" "${TMPDIR}/"
ln -s /Applications "${TMPDIR}/Applications"
hdiutil create -volname "RoonDisplay" -srcfolder "${TMPDIR}" \
    -ov -format UDZO RoonDisplay.dmg -quiet
rm -rf "${TMPDIR}"
echo "Done: RoonDisplay.dmg"
