#!/usr/bin/env bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"

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

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy binary
cp "$PROJECT_ROOT/app/.build/release/NotchCove" "$MACOS_DIR/NotchCove"
chmod +x "$MACOS_DIR/NotchCove"

# Generate Info.plist
cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>NotchCove</string>
    <key>CFBundleIdentifier</key>
    <string>com.notchcove.app</string>
    <key>CFBundleName</key>
    <string>NotchCove</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "✨ Build succeeded! App bundle created at:"
echo "   $APP_BUNDLE"
