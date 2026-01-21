#!/bin/bash
set -e

# Configuration
APP_NAME="Whispered"
BUNDLE_ID="com.whispered.app"
VERSION="1.0.0"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "🔨 Building $APP_NAME..."
swift build -c release

echo "📦 Creating app bundle..."

# Clean previous bundle
rm -rf "$APP_BUNDLE"

# Create bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Copy icon if exists
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
    echo "📎 Icon added"
fi

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>fr</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Whispered a besoin du microphone pour enregistrer votre voix et la transcrire en texte.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Whispered a besoin de contrôler d'autres applications pour insérer le texte transcrit.</string>
</dict>
</plist>
EOF

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Copy entitlements
if [ -f "Whispered.entitlements" ]; then
    cp "Whispered.entitlements" "$APP_BUNDLE/Contents/Resources/"
    echo "📜 Entitlements added"
fi

# Sign the app with Apple Development certificate (stable identity for TCC)
# This ensures macOS recognizes the app consistently for permissions
SIGNING_IDENTITY="Apple Development: Edgard Troadec (TQ826VX8L2)"

echo "🔏 Signing app with certificate: $SIGNING_IDENTITY"
codesign --force --deep --sign "$SIGNING_IDENTITY" --entitlements Whispered.entitlements "$APP_BUNDLE"

echo "✅ App bundle created: $APP_BUNDLE"
echo ""
echo "To install, run:"
echo "  cp -r \"$APP_BUNDLE\" /Applications/"
echo ""
echo "Or drag the app to your Applications folder."
