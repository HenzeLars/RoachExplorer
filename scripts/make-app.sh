#!/bin/zsh
# Build a release binary and install /Applications/Roach Explorer.app
# Ad-hoc signed, unsandboxed, so it can be opened from Finder.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
name="Roach Explorer"
app_dir="${APP_DIR:-/Applications}"
app="${app_dir}/${name}.app"
executable="$app/Contents/MacOS/RoachExplorer"

cd "$root"
swift build -c release

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# Build AppIcon.icns from the source image (1024x1024)
icon_src="$root/roach-explorer.jpeg"
iconset="$root/.build/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" --setProperty format png "$icon_src" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" --setProperty format png "$icon_src" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"

cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
cp "$root/.build/release/RoachExplorer" "$executable"
chmod 755 "$executable"

# Optional: stamp a version into the bundle. A release passes VERSION (for
# example v0.1.2); a local build takes the newest tag so About is truthful.
version="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || true)}"
if [ -n "$version" ]; then
  short="${version#v}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${short}" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${short}" "$app/Contents/Info.plist"
fi

xattr -cr "$app" 2>/dev/null || true
codesign --force --sign - "$app"

echo "$app"
