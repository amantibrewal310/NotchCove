#!/usr/bin/env bash
# Publishes the version in VERSION: tags it, uploads the zip to a GitHub
# release, and updates the cask in the Homebrew tap.
# Needs a clean, pushed main branch and `gh` logged in as the repo owner.
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
REPO="amantibrewal310/NotchCove"
TAP_REPO="amantibrewal310/homebrew-tap"
TAG="v$VERSION"
ZIP="$PROJECT_ROOT/dist/NotchCove-$VERSION.zip"

cd "$PROJECT_ROOT"
if [ -n "$(git status --porcelain)" ]; then
    echo "❌ Commit your changes first."
    exit 1
fi

"$PROJECT_ROOT/scripts/package.sh"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

echo "🏷  Tagging $TAG..."
git tag -a "$TAG" -m "NotchCove $VERSION"
git push origin "$TAG"

echo "🚀 Creating GitHub release..."
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "NotchCove $VERSION" \
    --notes "Install with Homebrew (Apple Silicon, macOS 14+):

\`\`\`
brew install --cask amantibrewal310/tap/notchcove
\`\`\`"

echo "🍺 Updating the Homebrew tap..."
TAP_DIR="$(mktemp -d)"
gh repo clone "$TAP_REPO" "$TAP_DIR"
mkdir -p "$TAP_DIR/Casks"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" \
    "$PROJECT_ROOT/packaging/notchcove.rb" > "$TAP_DIR/Casks/notchcove.rb"
git -C "$TAP_DIR" add Casks/notchcove.rb
git -C "$TAP_DIR" commit -m "notchcove $VERSION"
git -C "$TAP_DIR" push
rm -rf "$TAP_DIR"

echo "✨ Released $TAG. Install with: brew install --cask amantibrewal310/tap/notchcove"
