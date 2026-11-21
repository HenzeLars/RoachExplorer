#!/bin/zsh
# Build a release binary and install ~/Applications/Roach Explorer.app
# Ad-hoc signed, unsandboxed, so it can be opened from Finder.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
name="Roach Explorer"
app="$HOME/Applications/${name}.app"
executable="$app/Contents/MacOS/RoachExplorer"

cd "$root"
swift build -c release

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
cp "$root/.build/release/RoachExplorer" "$executable"
chmod 755 "$executable"
xattr -cr "$app" 2>/dev/null || true
codesign --force --sign - "$app"

echo "$app"
