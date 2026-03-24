#!/bin/bash
#
# Release script for Mac Tray Commands
#
# Usage: ./release.sh <version>
#   e.g. ./release.sh 1.0.1
#
# What it does:
#   1. Builds a Release binary signed with Developer ID
#   2. Submits to Apple for notarization and staples the ticket
#   3. Creates a DMG at /tmp/MacTrayCommands.dmg
#   4. Uploads to GitHub as a new release
#   5. Updates the Homebrew cask with new version and SHA
#
# Prerequisites:
#   - Xcode with Developer ID certificate
#   - Notarization credentials stored in keychain:
#     xcrun notarytool store-credentials "MacTrayCommands"
#   - GitHub CLI (gh) authenticated
#
set -euo pipefail

# Config
SCHEME="MacTrayCommands"
TEAM_ID="H7TH8723VJ"
SIGN_IDENTITY="Developer ID Application: Qian Chen (H7TH8723VJ)"
KEYCHAIN_PROFILE="MacTrayCommands"
REPO="elgs/mac-tray-commands"
TAP_REPO="elgs/homebrew-taps"
BUILD_DIR="/tmp/MacTrayCommandsBuild"
DMG_PATH="/tmp/MacTrayCommands.dmg"

# Parse version from args
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version>"
    echo "Example: ./release.sh 1.0.1"
    exit 1
fi

echo "==> Building Release..."
rm -rf "$BUILD_DIR"
xcodebuild -project MacTrayCommands.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    build \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

echo "==> Verifying signature..."
codesign -dvv "$BUILD_DIR/$SCHEME.app" 2>&1 | grep -E "Authority|Timestamp"

echo "==> Creating zip for notarization..."
cd "$BUILD_DIR"
rm -f "$SCHEME.zip"
ditto -c -k --keepParent "$SCHEME.app" "$SCHEME.zip"

echo "==> Submitting for notarization..."
xcrun notarytool submit "$SCHEME.zip" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "==> Stapling ticket..."
xcrun stapler staple "$BUILD_DIR/$SCHEME.app"

echo "==> Creating DMG..."
rm -rf /tmp/MacTrayCommandsDMG "$DMG_PATH"
mkdir -p /tmp/MacTrayCommandsDMG
cp -R "$BUILD_DIR/$SCHEME.app" /tmp/MacTrayCommandsDMG/
ln -s /Applications /tmp/MacTrayCommandsDMG/Applications
hdiutil create -volname "Mac Tray Commands" \
    -srcfolder /tmp/MacTrayCommandsDMG \
    -ov -format UDZO "$DMG_PATH"

SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo "==> DMG SHA256: $SHA256"

echo "==> Updating GitHub release v$VERSION..."
gh release delete "v$VERSION" --repo "$REPO" --yes 2>/dev/null || true
gh release create "v$VERSION" "$DMG_PATH" \
    --repo "$REPO" \
    --title "v$VERSION" \
    --notes "## Mac Tray Commands v$VERSION

Signed and notarized macOS menu bar app for running custom shell commands.

**SHA256:** \`$SHA256\`"

echo "==> Updating Homebrew cask..."
TAP_DIR=$(mktemp -d)
gh repo clone "$TAP_REPO" "$TAP_DIR" -- -q
cd "$TAP_DIR"
sed -i '' "s/version \".*\"/version \"$VERSION\"/" Casks/mac-tray-commands.rb
sed -i '' "s/sha256 \".*\"/sha256 \"$SHA256\"/" Casks/mac-tray-commands.rb
git add Casks/mac-tray-commands.rb
git commit -m "Update mac-tray-commands to v$VERSION"
git push
rm -rf "$TAP_DIR"

echo "==> Updating local tap..."
cd "$(brew --repo elgs/taps)" && git pull -q

echo ""
echo "==> Done! Released v$VERSION"
echo "    GitHub: https://github.com/$REPO/releases/tag/v$VERSION"
echo "    Install: brew tap elgs/taps && brew install --cask mac-tray-commands"
