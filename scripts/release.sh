#!/usr/bin/env bash
# Publishes the version in VERSION: tags it, uploads the zip to a GitHub
# release, and updates the cask in the Homebrew tap.
# Needs a clean, pushed main branch and `gh` logged in as the repo owner
# (or GH_TOKEN="$(gh auth token --user amantibrewal310)").
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
# Same SSH remote and git identity as this repo (both can be per-folder settings)
TAP_URL="$(git remote get-url origin | sed 's#/NotchCove\(\.git\)\{0,1\}$#/homebrew-tap.git#')"
git clone -q "$TAP_URL" "$TAP_DIR"
mkdir -p "$TAP_DIR/Casks"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" \
    "$PROJECT_ROOT/packaging/notchcove.rb" > "$TAP_DIR/Casks/notchcove.rb"
git -C "$TAP_DIR" add Casks/notchcove.rb
git -C "$TAP_DIR" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
    commit -m "notchcove $VERSION"
git -C "$TAP_DIR" push -q origin HEAD
rm -rf "$TAP_DIR"

echo "✨ Released $TAG. Install with: brew install --cask amantibrewal310/tap/notchcove"
