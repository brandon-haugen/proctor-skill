#!/bin/bash
#
# Publish proctor-skill to npm.
#
# Usage:
#   bash publish.sh          # publish current version
#   bash publish.sh 0.0.3    # bump to 0.0.3, tag, and publish

set -euo pipefail

if [ -n "$(git status --porcelain)" ]; then
  echo "Error: working tree is not clean. Commit or stash changes first."
  exit 1
fi

VERSION="${1:-}"

if [ -n "$VERSION" ]; then
  CURRENT=$(node -p "require('./package.json').version")
  if [ "$VERSION" != "$CURRENT" ]; then
    npm version "$VERSION" --no-git-tag-version
    git add package.json
    git commit -m "Bump version to $VERSION"
    echo "Bumped to $VERSION"
  fi
else
  VERSION=$(node -p "require('./package.json').version")
fi

if ! git tag -l "$VERSION" | grep -q .; then
  git tag "$VERSION"
  echo "Created tag $VERSION"
fi

echo "Publishing version $VERSION"

echo ""
echo "Publishing proctor-skill@$VERSION to npm..."
npm publish

echo ""
echo "Done! Published proctor-skill@$VERSION"
echo "  npm: https://www.npmjs.com/package/proctor-skill"
echo ""
echo "Don't forget to push the tag:"
echo "  git push origin main && git push origin $VERSION"
