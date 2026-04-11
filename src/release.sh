#!/usr/bin/env bash
# Package a release zip from a git version tag.
#
# Usage:
#   ./release.sh              # package HEAD, tag it with next patch version
#   ./release.sh v1.2.3       # package existing tag v1.2.3
#   ./release.sh --tag v1.2.3 # create tag at HEAD, then package it
#
# Output: dist/ridgeguard-<version>.zip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"

die() { echo "ERROR: $1" >&2; exit 1; }

# --- Parse arguments ---

CREATE_TAG=false
VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)
            CREATE_TAG=true
            VERSION="$2"
            shift 2
            ;;
        --tag=*)
            CREATE_TAG=true
            VERSION="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] [VERSION]"
            echo ""
            echo "Package a release zip from a git version tag."
            echo ""
            echo "Arguments:"
            echo "  VERSION          Existing git tag to package (e.g., v1.2.3)"
            echo ""
            echo "Options:"
            echo "  --tag VERSION    Create a new tag at HEAD, then package it"
            echo "  -h, --help       Show this help message"
            echo ""
            echo "If no version is given, the next patch version is auto-tagged."
            echo "Output: dist/ridgeguard-<version>.zip"
            exit 0
            ;;
        v[0-9]*)
            VERSION="$1"
            shift
            ;;
        *)
            die "Unknown argument: $1 (see --help)"
            ;;
    esac
done

cd "$SCRIPT_DIR"

# Must be in a git repo
git rev-parse --git-dir >/dev/null 2>&1 || die "Not a git repository"

# --- Resolve or create the version tag ---

if [[ -z "$VERSION" ]]; then
    # Auto-increment: find latest vX.Y.Z tag, bump patch
    latest=$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)
    if [[ -z "$latest" ]]; then
        VERSION="v1.0.0"
    else
        IFS='.' read -r major minor patch <<< "${latest#v}"
        VERSION="v${major}.${minor}.$((patch + 1))"
    fi
    CREATE_TAG=true
    echo "Auto-versioning: $VERSION"
fi

# Validate version format
if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Invalid version format: $VERSION (expected vX.Y.Z)"
fi

if [[ "$CREATE_TAG" == true ]]; then
    if git rev-parse "$VERSION" >/dev/null 2>&1; then
        die "Tag $VERSION already exists. Use a different version or omit --tag to package the existing one."
    fi
    # Ensure working tree is clean before tagging
    if [[ -n "$(git status --porcelain)" ]]; then
        die "Working tree is not clean. Commit or stash changes before tagging."
    fi
    err_file="$(mktemp)"
    if git tag -s "$VERSION" -m "Release $VERSION" 2>"$err_file"; then
        rm -f "$err_file"
        echo "Created signed tag: $VERSION"
    else
        signing_err="$(cat "$err_file")"
        rm -f "$err_file"
        # Fall back to unsigned tag only when signing is unavailable
        if printf '%s\n' "$signing_err" | grep -qiE 'no secret key|secret key not available|signing key.*not found|gpg.*not found|cannot run gpg'; then
            echo "WARNING: Tag signing unavailable; creating unsigned annotated tag" >&2
            git tag -a "$VERSION" -m "Release $VERSION"
            echo "Created tag: $VERSION (unsigned)"
        else
            printf '%s\n' "$signing_err" >&2
            die "Failed to create signed tag $VERSION"
        fi
    fi
else
    # Verify the tag exists
    git rev-parse "$VERSION" >/dev/null 2>&1 || die "Tag $VERSION does not exist. Use --tag to create it."
fi

# --- Build the zip ---

mkdir -p "$DIST_DIR"
ZIPFILE="$DIST_DIR/ridgeguard-${VERSION}.zip"

# Use git archive to produce a clean export (no .git, respects .gitignore)
git archive --format=zip --prefix="ridgeguard-${VERSION#v}/" "$VERSION" > "$ZIPFILE"

echo ""
echo "Release packaged: $ZIPFILE"
echo "  Tag:    $VERSION"
echo "  Commit: $(git rev-list -1 "$VERSION" | head -c 10)"
echo "  Size:   $(du -h "$ZIPFILE" | cut -f1)"
