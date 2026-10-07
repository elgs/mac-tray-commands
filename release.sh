#!/bin/bash
#
# Release script: build, sign, notarize, publish
#
# Usage: ./release.sh <version> [--force]
#   e.g. ./release.sh 1.1.0
#   --force allows re-releasing a version whose tag already exists
#   (replaces the tag, the GitHub release, and the cask entry)
#
# Nothing is pushed until the app and the DMG have both been notarized: a
# failed run leaves only a local version-bump commit and a local tag.
#
# Prerequisites:
#   - Xcode and the pinned Developer ID Application certificate with its
#     private key (import the Application .p12 into each release Mac's login keychain)
#   - Notarization credentials stored in keychain:
#     xcrun notarytool store-credentials "MacTrayCommands"
#   - GitHub CLI (gh) authenticated
#   - .project.env in the same directory
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"
source "$REPO_DIR/.project.env"

VERSION="${1:-}"
FORCE="${2:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version> [--force]"
    echo "Example: ./release.sh 1.1.0"
    exit 1
fi

# Plain dotted digits only: the cask's version and download URL are built
# from this string, and Homebrew compares cask versions with this shape.
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "ERROR: version must be plain dotted digits (e.g. 1.2.3), got: $VERSION"
    exit 1
fi

# Reusing a version number silently replaces the old tag, GitHub release,
# and cask entry (tag -f / push -f / gh release delete below). Make that
# an explicit choice rather than a typo's outcome.
if git rev-parse -q --verify "refs/tags/v$VERSION" > /dev/null && [ "$FORCE" != "--force" ]; then
    echo "ERROR: tag v$VERSION already exists — releasing would replace it"
    echo "       To re-release deliberately: ./release.sh $VERSION --force"
    exit 1
fi

# Select the G2 release certificate by fingerprint: older certificates can
# have the same name.
# Keep an empty lookup alive so the error below explains what to import.
SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | grep -F "Developer ID Application:" | grep -F "($TEAM_ID)" \
    | awk -v fingerprint="$SIGNING_CERT_FINGERPRINT" '$2 == fingerprint && !found { print $2; found = 1 }' || true)"
if [ -z "$SIGN_IDENTITY" ]; then
    echo "ERROR: no valid pinned \"Developer ID Application\" certificate for team $TEAM_ID ($SIGNING_CERT_FINGERPRINT) in the keychain"
    echo "       Import the new Application certificate and private key (.p12) into this Mac's login keychain, unlock it, and retry."
    exit 1
fi
BUILD_DIR="/tmp/${SCHEME}Build"
APP_DIR="$BUILD_DIR/$SCHEME.app"
DMG_PATH="/tmp/${SCHEME}.dmg"
TAP_NAME="${HOMEBREW_TAP_REPO/homebrew-/}"

echo "==> Verifying clean working tree..."
# git status --porcelain (unlike git diff HEAD) also catches untracked
# files: the version-bump commit below uses `git add -A`, so a forgotten
# file would be committed and compiled into the shipped binary by accident.
if [ -n "$(git status --porcelain)" ]; then
    echo "ERROR: working tree not clean — commit, stash, or remove these before releasing:"
    git status --short
    exit 1
fi

echo "==> Checking publishing credentials..."
# Everything that can fail without side effects is checked here, before
# the version bump is committed or anything is tagged.
command -v gh > /dev/null || { echo "ERROR: gh is not installed (brew install gh)"; exit 1; }
gh auth status > /dev/null 2>&1 || { echo "ERROR: gh is not authenticated — run: gh auth login"; exit 1; }
git push --dry-run --porcelain origin HEAD > /dev/null \
    || { echo "ERROR: cannot push the current branch to origin — nothing was released"; exit 1; }
if ! xcrun notarytool history --keychain-profile "$SCHEME" > /dev/null 2>&1; then
    echo "ERROR: no working notarization credentials stored as \"$SCHEME\" — (re)create them once:"
    echo "       xcrun notarytool store-credentials \"$SCHEME\" --apple-id <id> --team-id $TEAM_ID"
    exit 1
fi

BUILD_NUMBER=$(git rev-list HEAD --count)
echo "==> Setting version to $VERSION ($BUILD_NUMBER)..."
sed -i '' "s/MARKETING_VERSION = .*/MARKETING_VERSION = $VERSION;/" "$SCHEME.xcodeproj/project.pbxproj"
sed -i '' "s/CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/" "$SCHEME.xcodeproj/project.pbxproj"

echo "==> Committing version bump..."
git add -A
git commit -m "Bump version to $VERSION ($BUILD_NUMBER)"

echo "==> Tagging v$VERSION..."
git tag -f "v$VERSION"

echo "==> Building Release..."
rm -rf "$BUILD_DIR"
xcodebuild -project "$SCHEME.xcodeproj" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS,arch=arm64' \
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
codesign -dvv "$APP_DIR" 2>&1 | grep -E "Authority|Timestamp"

echo "==> Creating zip for notarization..."
cd "$BUILD_DIR"
rm -f "$SCHEME.zip"
ditto -c -k --keepParent "$SCHEME.app" "$SCHEME.zip"

echo "==> Submitting for notarization..."
xcrun notarytool submit "$SCHEME.zip" \
    --keychain-profile "$SCHEME" \
    --wait

echo "==> Stapling app ticket..."
xcrun stapler staple "$APP_DIR"

echo "==> Creating DMG..."
rm -rf "/tmp/${SCHEME}DMG" "$DMG_PATH"
mkdir -p "/tmp/${SCHEME}DMG"
cp -R "$APP_DIR" "/tmp/${SCHEME}DMG/"
ln -s /Applications "/tmp/${SCHEME}DMG/Applications"
hdiutil create -volname "$SCHEME" \
    -srcfolder "/tmp/${SCHEME}DMG" \
    -ov -format UDZO "$DMG_PATH"

# The disk image gets the same treatment as the app it carries. The app's
# stapled ticket is what clears a first launch, so this is not what makes the
# download open — but an unsigned image reads as "no usable signature" to any
# assessment of the file itself, and `spctl -a -t open` is exactly what macOS
# runs when a quarantined image is opened.
echo "==> Signing DMG..."
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"

echo "==> Notarizing DMG..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$SCHEME" \
    --wait

echo "==> Stapling DMG ticket..."
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# AFTER the signing and stapling above, both of which rewrite the file: a hash
# taken any earlier is the hash of an image nobody will ever download, and
# `brew install` would refuse the real one as a checksum mismatch.
SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo "==> DMG SHA256: $SHA256"

echo "==> Pushing version bump and tag..."
cd "$REPO_DIR"
git push
git push origin "v$VERSION" -f

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
sed -i '' "s/version \".*\"/version \"$VERSION\"/" "Casks/${CASK_NAME}.rb"
sed -i '' "s/sha256 \".*\"/sha256 \"$SHA256\"/" "Casks/${CASK_NAME}.rb"
git add "Casks/${CASK_NAME}.rb"
git commit -m "Update ${CASK_NAME} to v$VERSION"
git push
cd "$REPO_DIR"
rm -rf "$TAP_DIR"

echo "==> Updating local tap..."
cd "$(brew --repo "$TAP_NAME")" && git pull -q

echo ""
echo "==> Done! Released v$VERSION"
echo "    GitHub: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
echo "    Install: brew tap $TAP_NAME && brew install --cask ${CASK_NAME}"
