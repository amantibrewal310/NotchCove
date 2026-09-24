#!/usr/bin/env bash
# Renders app/Resources/AppIcon.svg into app/Resources/AppIcon.icns.
# Only needed after editing the SVG; the .icns is committed.
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$PROJECT_ROOT/app/Resources/AppIcon.svg"
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# Render once at 1024 with AppKit's SVG support, then downscale for each size
cat > "$WORK/render.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
guard let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else { fatalError("can't read SVG") }
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
SWIFT
swift "$WORK/render.swift" "$SVG" "$WORK/1024.png"

for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

OUT="$PROJECT_ROOT/app/Resources/AppIcon.icns"
if command -v pngquant >/dev/null 2>&1; then
    # Shrink the PNGs (visually identical), then pack them as-is: iconutil
    # would re-encode them and undo most of the saving.
    pngquant --quality 80-98 --speed 1 --strip --force --ext .png "$ICONSET"/*.png
    python3 - "$ICONSET" "$OUT" <<'PY'
import struct, sys
iconset, out = sys.argv[1], sys.argv[2]
types = [("icp4", "16x16"), ("ic11", "16x16@2x"), ("icp5", "32x32"), ("ic12", "32x32@2x"),
         ("ic07", "128x128"), ("ic13", "128x128@2x"), ("ic08", "256x256"), ("ic14", "256x256@2x"),
         ("ic09", "512x512"), ("ic10", "512x512@2x")]
body = b""
for code, name in types:
    data = open(f"{iconset}/icon_{name}.png", "rb").read()
    body += code.encode() + struct.pack(">I", len(data) + 8) + data
open(out, "wb").write(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY
else
    echo "ℹ️  pngquant not found (brew install pngquant); writing an uncompressed icon"
    iconutil -c icns "$ICONSET" -o "$OUT"
fi
rm -rf "$WORK"
echo "✨ app/Resources/AppIcon.icns"
