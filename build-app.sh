#!/bin/zsh
# Builds MacNotes.app in the repo root.
set -e
cd "$(dirname "$0")"

swift build -c release

APP=MacNotes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/MacNotes "$APP/Contents/MacOS/MacNotes"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MacNotes</string>
    <key>CFBundleDisplayName</key>
    <string>MacNotes</string>
    <key>CFBundleIdentifier</key>
    <string>com.levihanlen.macnotes</string>
    <key>CFBundleExecutable</key>
    <string>MacNotes</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- So the panel can be pointed at a dev server on localhost. -->
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

codesign --force -s - "$APP"
echo "Built $APP"
