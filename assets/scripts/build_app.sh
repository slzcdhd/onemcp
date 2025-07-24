#!/bin/bash

set -e

APP_NAME="OneMCP"
BUNDLE_ID="com.onemcp.OneMCP"
VERSION="1.0.0"
BUILD_DIR=".build/arm64-apple-macosx/release"
APP_DIR="${APP_NAME}.app"

echo "🚀 Building ${APP_NAME} macOS app bundle..."

# Clean previous build
rm -rf "${APP_DIR}"

# Build the project
echo "📦 Building Swift project..."
swift build --configuration release

# Create app bundle structure
echo "🏗️  Creating app bundle structure..."
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
mkdir -p "${APP_DIR}/Contents/Frameworks"

# Copy executable
echo "📋 Copying executable..."
cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/"

# Create Info.plist
echo "📄 Creating Info.plist..."
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
    <string>1</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2025 OneMCP. All rights reserved.</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>OneMCP</string>
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
</dict>
</plist>
EOF

# Create app icon
echo "🎨 Creating app icon..."
if [ -f "assets/icons/OneMCP.icns" ]; then
    cp "assets/icons/OneMCP.icns" "${APP_DIR}/Contents/Resources/"
    echo "✅ Copied OneMCP.icns to app bundle"
else
    echo "⚠️  OneMCP.icns not found in assets/icons/"
fi

# Copy status bar icons
if [ -f "assets/icons/MenuBarIcon.icns" ]; then
    cp "assets/icons/MenuBarIcon.icns" "${APP_DIR}/Contents/Resources/"
    echo "✅ Copied MenuBarIcon.icns to app bundle"
fi

if [ -f "assets/icons/menubar_icon_16.png" ]; then
    cp "assets/icons/menubar_icon_16.png" "${APP_DIR}/Contents/Resources/"
    echo "✅ Copied menubar_icon_16.png to app bundle"
fi

if [ -f "assets/icons/menubar_icon_32.png" ]; then
    cp "assets/icons/menubar_icon_32.png" "${APP_DIR}/Contents/Resources/"
    echo "✅ Copied menubar_icon_32.png to app bundle"
fi

# Set permissions
echo "🔒 Setting permissions..."
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Code signing (if certificates are available)
if command -v codesign &> /dev/null; then
    echo "✍️  Code signing..."
    codesign --force --deep --sign - "${APP_DIR}" || echo "⚠️  Code signing failed (development mode)"
fi

echo "✅ App bundle created successfully: ${APP_DIR}"
echo "📱 To run: open ${APP_DIR}"
echo "📦 To install: cp -r ${APP_DIR} /Applications/"

# Verify bundle
echo "🔍 Verifying bundle..."
if [[ -f "${APP_DIR}/Contents/MacOS/${APP_NAME}" && -f "${APP_DIR}/Contents/Info.plist" ]]; then
    echo "✅ Bundle verification passed"
    ls -la "${APP_DIR}/Contents/"
else
    echo "❌ Bundle verification failed"
    exit 1
fi 