#!/bin/zsh
# Builds build/Blender Render Monitor.app
set -euo pipefail
cd "${0:A:h}"

swift build -c release
APP="build/Blender Render Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BlenderRenderMonitor "$APP/Contents/MacOS/"
cp blender/render_monitor.py "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Blender Render Monitor</string>
    <key>CFBundleDisplayName</key><string>Blender Render Monitor</string>
    <key>CFBundleIdentifier</key><string>local.seldon.BlenderRenderMonitor</string>
    <key>CFBundleExecutable</key><string>BlenderRenderMonitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP"
