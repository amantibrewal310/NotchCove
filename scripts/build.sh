#!/usr/bin/env bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/usr/local/opt/rustup/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
    echo "❌ cargo not found. Install Rust: brew install rustup && rustup default stable"
    exit 1
fi

echo "🦀 Step 1/3: Building Rust Core (cove-core)..."
cd "$PROJECT_ROOT/core"
cargo build --release

echo "🍏 Step 2/3: Building Swift App (NotchCove)..."
cd "$PROJECT_ROOT/app"
swift build -c release

echo "📦 Step 3/3: Assembling macOS App Bundle (NotchCove.app)..."
BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/NotchCove.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Start from a clean bundle so no stale files end up in a release
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$PROJECT_ROOT/app/.build/release/NotchCove" "$MACOS_DIR/NotchCove"
strip "$MACOS_DIR/NotchCove"

cp "$PROJECT_ROOT/app/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

cat << EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>NotchCove</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.notchcove.app</string>
    <key>CFBundleName</key>
    <string>NotchCove</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>NotchCove adds new screenshots to the shelf when that option is on.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>NotchCove shows files you put on the shelf.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>NotchCove shows files you put on the shelf.</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Sign the app bundle ad-hoc (mandatory on Apple Silicon / macOS 14+)
codesign --force --deep --sign - "$APP_BUNDLE"

echo "✨ Build succeeded! App bundle created and signed at:"
echo "   $APP_BUNDLE"
