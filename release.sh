#!/bin/bash
#
# Release script: build, sign, notarize, publish
#
# Usage: ./release.sh <version>
#   e.g. ./release.sh 1.0.1
#
# Prerequisites:
#   - Xcode with Developer ID certificate
#   - Notarization credentials stored in keychain:
#     xcrun notarytool store-credentials "<SCHEME>"
#   - GitHub CLI (gh) authenticated
#   - .project.env in the same directory
#
set -euo pipefail

source "$(dirname "$0")/.project.env"

SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep "$TEAM_ID" | head -1 | sed 's/.*"\(.*\)"/\1/')"
BUILD_DIR="/tmp/${SCHEME}Build"
DMG_PATH="/tmp/${SCHEME}.dmg"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version>"
    echo "Example: ./release.sh 1.0.1"
    exit 1
fi

echo "==> Tagging v$VERSION..."
git tag -f "v$VERSION"

echo "==> Building Release..."
rm -rf "$BUILD_DIR"
xcodebuild -project "$SCHEME.xcodeproj" \
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
    --keychain-profile "$SCHEME" \
    --wait

echo "==> Stapling ticket..."
xcrun stapler staple "$BUILD_DIR/$SCHEME.app"

echo "==> Creating DMG..."
rm -rf "/tmp/${SCHEME}DMG" "$DMG_PATH"
mkdir -p "/tmp/${SCHEME}DMG"
cp -R "$BUILD_DIR/$SCHEME.app" "/tmp/${SCHEME}DMG/"
ln -s /Applications "/tmp/${SCHEME}DMG/Applications"
hdiutil create -volname "$SCHEME" \
    -srcfolder "/tmp/${SCHEME}DMG" \
    -ov -format UDZO "$DMG_PATH"

SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo "==> DMG SHA256: $SHA256"

echo "==> Updating GitHub release v$VERSION..."
gh release delete "v$VERSION" --repo "$GITHUB_REPO" --yes 2>/dev/null || true
gh release create "v$VERSION" "$DMG_PATH" \
    --repo "$GITHUB_REPO" \
    --title "v$VERSION" \
    --notes "## $SCHEME v$VERSION

Signed and notarized.

**SHA256:** \`$SHA256\`"

echo "==> Updating Homebrew cask..."
TAP_DIR=$(mktemp -d)
gh repo clone "$HOMEBREW_TAP_REPO" "$TAP_DIR" -- -q
cd "$TAP_DIR"
sed -i '' "s/version \".*\"/version \"$VERSION\"/" "Casks/${GITHUB_REPO#*/}.rb"
sed -i '' "s/sha256 \".*\"/sha256 \"$SHA256\"/" "Casks/${GITHUB_REPO#*/}.rb"
git add "Casks/${GITHUB_REPO#*/}.rb"
git commit -m "Update ${GITHUB_REPO#*/} to v$VERSION"
git push
rm -rf "$TAP_DIR"

echo "==> Updating local tap..."
cd "$(brew --repo elgs/taps)" && git pull -q

echo ""
echo "==> Done! Released v$VERSION"
echo "    GitHub: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
echo "    Install: brew tap elgs/taps && brew install --cask ${GITHUB_REPO#*/}"
