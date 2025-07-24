#!/bin/bash

set -e

APP_NAME="OneMCP"
BUNDLE_ID="com.onemcp.OneMCP"
VERSION="1.0.0"
BUILD_DIR=".build/arm64-apple-macosx/release"
APP_DIR="${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

echo "🚀 Building ${APP_NAME} v${VERSION} for release..."

# Clean previous builds
rm -rf "${APP_DIR}" "${DMG_NAME}" 2>/dev/null || true

# Build for release
echo "📦 Building Swift project (Release)..."
swift build --configuration release

# Create app bundle
echo "🏗️  Creating app bundle..."
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Copy executable
cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/"

# Copy main app icon if it exists
if [ -f "assets/icons/${APP_NAME}.icns" ]; then
    cp "assets/icons/${APP_NAME}.icns" "${APP_DIR}/Contents/Resources/"
    echo "✅ Added custom icon to app bundle"
    ICON_ENTRY="    <key>CFBundleIconFile</key>
    <string>${APP_NAME}</string>"
else
    echo "⚠️ No custom icon found, using default"
    ICON_ENTRY=""
fi

# Copy status bar icons
if [ -f "assets/icons/MenuBarIcon.icns" ]; then
    cp "assets/icons/MenuBarIcon.icns" "${APP_DIR}/Contents/Resources/"
    echo "✅ Added MenuBarIcon.icns to app bundle"
fi

if [ -f "assets/icons/menubar_icon_16.png" ]; then
    cp "assets/icons/menubar_icon_16.png" "${APP_DIR}/Contents/Resources/"
    echo "✅ Added menubar_icon_16.png to app bundle"
fi

if [ -f "assets/icons/menubar_icon_32.png" ]; then
    cp "assets/icons/menubar_icon_32.png" "${APP_DIR}/Contents/Resources/"
    echo "✅ Added menubar_icon_32.png to app bundle"
fi

# Create comprehensive Info.plist
cat > "${APP_DIR}/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>OneMCP Server Aggregator</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>${ICON_ENTRY}
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2025 OneMCP. All rights reserved.</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>LSBackgroundOnly</key>
    <false/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSAppleEventsUsageDescription</key>
    <string>OneMCP needs to aggregate MCP server capabilities.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>OneMCP connects to remote MCP servers.</string>
</dict>
</plist>
EOF

# Set permissions
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Code signing
echo "✍️  Code signing..."
if codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null; then
    echo "✅ Code signing successful"
else
    echo "⚠️  Code signing failed (development mode)"
fi

# Create DMG for distribution
echo "💿 Creating DMG..."
if command -v hdiutil &> /dev/null; then
    # Create temporary directory
    TMP_DIR=$(mktemp -d)
    cp -r "${APP_DIR}" "${TMP_DIR}/"
    
    # Create Applications symlink
    ln -s /Applications "${TMP_DIR}/Applications"
    
    # Create DMG
    hdiutil create -volname "${APP_NAME}" -srcfolder "${TMP_DIR}" -ov -format UDZO "${DMG_NAME}"
    
    # Cleanup
    rm -rf "${TMP_DIR}"
    
    echo "✅ DMG created: ${DMG_NAME}"
else
    echo "⚠️  hdiutil not found, skipping DMG creation"
fi

# App bundle info
echo ""
echo "📋 Build Summary:"
echo "App Bundle: ${APP_DIR}"
echo "DMG File: ${DMG_NAME}"
echo "Version: ${VERSION}"
echo "Bundle ID: ${BUNDLE_ID}"
echo ""

# Verification
echo "🔍 Verifying app bundle..."
if [[ -f "${APP_DIR}/Contents/MacOS/${APP_NAME}" ]]; then
    echo "✅ Executable: OK"
else
    echo "❌ Executable: Missing"
    exit 1
fi

if [[ -f "${APP_DIR}/Contents/Info.plist" ]]; then
    echo "✅ Info.plist: OK"
else
    echo "❌ Info.plist: Missing"
    exit 1
fi

# Check for icon
if [ -f "${APP_DIR}/Contents/Resources/${APP_NAME}.icns" ]; then
    echo "✅ Custom icon: OK"
else
    echo "⚠️ Custom icon: Not included (will use default)"
fi

# Bundle info
echo ""
echo "📊 Bundle Information:"
ls -la "${APP_DIR}/Contents/"
if [ -d "${APP_DIR}/Contents/Resources" ]; then
    echo ""
    echo "📦 Resources:"
    ls -la "${APP_DIR}/Contents/Resources/" 2>/dev/null || echo "No resources found"
fi

echo ""
echo "🎉 Release build complete!"
echo "📱 To test: open ${APP_DIR}"
echo "📦 To install: cp -r ${APP_DIR} /Applications/"
echo "💿 To distribute: Use ${DMG_NAME}" 