#!/bin/bash
# Ship a version of Redraft:
#   make release V=0.1.1
#
# 1. Sets the version in project.yml and commits it
# 2. Builds a Developer ID signed, notarized dmg (make dmg)
# 3. Tags vX.Y.Z and publishes a GitHub Release with the dmg attached
#    (notes are generated from the commits since the last release)
# 4. Signs the dmg with the update key and adds it to appcast.xml, so every
#    installed Redraft offers the update (Sparkle)
# 5. Installs that same notarized app into /Applications
set -euo pipefail

version="${1:-}"
current=$(grep MARKETING_VERSION project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [[ -z "$version" ]]; then
    echo "Usage: make release V=<version>   (current version: $current)" >&2
    exit 2
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version should look like 1.2.3, got '$version'." >&2
    exit 2
fi
tag="v$version"

# Preflight: everything that could stop us halfway, checked up front.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit or stash your changes first; a release is built from a clean tree." >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1; then
    echo "$tag already exists. Pick a new version (current: $current)." >&2
    exit 1
fi
gh auth status >/dev/null 2>&1 || { echo "Sign in to GitHub first: gh auth login" >&2; exit 1; }
sign_update=$(find build/SourcePackages/artifacts -path "*Sparkle/bin/sign_update" 2>/dev/null | head -1)
if [[ -z "$sign_update" ]]; then
    xcodebuild -resolvePackageDependencies -project Redraft.xcodeproj -scheme Redraft -derivedDataPath build >/dev/null
    sign_update=$(find build/SourcePackages/artifacts -path "*Sparkle/bin/sign_update" | head -1)
fi
[[ -n "$sign_update" ]] || { echo "Couldn't find Sparkle's sign_update tool." >&2; exit 1; }

# The update key: this Mac must hold the private key matching the public key
# built into the app, or installed copies would reject the update.
expected_key=$(grep SUPublicEDKey project.yml | head -1 | awk '{print $2}')
# Kept under its own Keychain account, apart from any other app's update key.
key_account=redraft
this_mac_key=$("$(dirname "$sign_update")/generate_keys" --account "$key_account" -p 2>/dev/null | tail -1 || true)
if [[ "$this_mac_key" != "$expected_key" ]]; then
    if [[ -z "$this_mac_key" || "$this_mac_key" == *rror* ]]; then
        echo "This Mac doesn't have the Redraft update key." >&2
    else
        echo "This Mac has a different update key than the app expects." >&2
    fi
    echo "Import it from your backup: paste it into a file, then run" >&2
    echo "  $(dirname "$sign_update")/generate_keys --account $key_account -f <file>   (and delete the file)" >&2
    exit 1
fi

# Up to date with GitHub: releasing from a stale copy could reuse a build
# number or drop an earlier release from the update feed.
git fetch -q origin
branch=$(git rev-parse --abbrev-ref HEAD)
if ! git merge-base --is-ancestor "origin/$branch" HEAD 2>/dev/null; then
    echo "Your copy is behind GitHub. Run 'git pull' first, then release." >&2
    exit 1
fi
notary="${NOTARY:-MyWriter}"   # where the Apple ID login for notarizing is kept
xcrun notarytool history --keychain-profile "$notary" >/dev/null 2>&1 || {
    echo "Notarization credentials missing. Run: xcrun notarytool store-credentials $notary --apple-id <email> --team-id KFY97BH6J8" >&2
    exit 1
}

echo "==> Releasing Redraft $version (was $current)"

previous_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)

# 1. Version: the marketing version, plus a build number that always goes up.
if [[ "$version" != "$current" ]]; then
    build=$(grep CURRENT_PROJECT_VERSION project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
    sed -i '' "s/MARKETING_VERSION: \"$current\"/MARKETING_VERSION: \"$version\"/" project.yml
    sed -i '' "s/CURRENT_PROJECT_VERSION: \"$build\"/CURRENT_PROJECT_VERSION: \"$((build + 1))\"/" project.yml
    git commit -qm "Release $version" project.yml
fi

# 2. Signed, notarized disk image.
make dmg
dmg="dist/Redraft-$version.dmg"
[[ -f "$dmg" ]] || { echo "Expected $dmg after make dmg." >&2; exit 1; }

# 3. Publish.
git push -q origin HEAD
git tag -a "$tag" -m "Redraft $version"
git push -q origin "$tag"
gh release create "$tag" "$dmg" --title "Redraft $version" --generate-notes \
    --notes "Download \`Redraft-$version.dmg\`, open it, and drag Redraft to Applications. Signed with Developer ID and notarized by Apple."

# 4. Update feed: sign the dmg with the update key and add it to appcast.xml.
build=$(grep CURRENT_PROJECT_VERSION project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
signed=$("$sign_update" --account "$key_account" "$dmg")   # sparkle:edSignature="…" length="…"
signature=$(sed -E 's/.*edSignature="([^"]+)".*/\1/' <<<"$signed")
length=$(sed -E 's/.*length="([0-9]+)".*/\1/' <<<"$signed")
notes=$(mktemp)
if [[ -n "$previous_tag" ]]; then
    # Leave out this script's own commits (the version bump and the feed update).
    git log --format=%s "$previous_tag..HEAD" | grep -vE '^(Release|Appcast:) ' > "$notes" || true
else
    echo "First release with automatic updates." > "$notes"
fi
url="https://github.com/brettsmith212/redraft/releases/download/$tag/Redraft-$version.dmg"
Tools/appcast.py "$version" "$build" "$url" "$length" "$signature" "$notes"
rm -f "$notes"
git commit -qm "Appcast: Redraft $version" appcast.xml
git push -q origin HEAD

# 5. Install the official copy.
pkill -x Redraft 2>/dev/null && sleep 1 || true
mount=$(diskutil image attach --readOnly --nobrowse "$dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')
rm -rf /Applications/Redraft.app
ditto "$mount/Redraft.app" /Applications/Redraft.app
diskutil eject "$mount" >/dev/null
spctl -a /Applications/Redraft.app
open /Applications/Redraft.app

echo "==> Redraft $version is published and installed."
gh release view "$tag" --json url -q .url
