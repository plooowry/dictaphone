#!/bin/zsh
# Builds Dictaphone.app (menu-bar app, ⌘D to record/stop)
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Dictaphone.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Dictaphone $APP/Contents/MacOS/
cp -R .build/release/*.bundle $APP/Contents/Resources/ 2>/dev/null || true
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Dictaphone</string>
<key>CFBundleIdentifier</key><string>local.dictaphone</string>
<key>CFBundleExecutable</key><string>Dictaphone</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Dictaphone records your voice to transcribe it.</string>
</dict></plist>
PL
codesign --force --deep --sign - $APP
echo "Built $PWD/$APP"

# Zip for sharing (upload to a GitHub Release)
mkdir -p dist && rm -f dist/Dictaphone-macOS.zip
ditto -c -k --keepParent $APP dist/Dictaphone-macOS.zip
echo "Packaged $PWD/dist/Dictaphone-macOS.zip"
