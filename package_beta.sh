#!/bin/zsh
# Build the app and publish it to the Dropbox "Beta Releases" folder that Buddy
# shares as a FOLDER link (link stays valid no matter what files change inside).
#
#   Phantom Control Beta Releases/     <- the shared folder
#   ├── Latest Version/                <- testers grab this
#   │   ├── READ ME FIRST.txt          (edit by hand when needed)
#   │   ├── Phantom Control.zip        (the app — refreshed here)
#   │   ├── Phantom Control — Quick Start.pdf
#   │   └── Release Notes.md           (from CHANGELOG.md)
#   └── Previous Versions/             <- old marketing versions, auto-archived
#
# Same MARKETING version (VERSION file) = Latest Version is just updated.
# When VERSION changes, the old Latest Version is zipped into Previous Versions
# first, so testers can always grab an older build if a new one regresses.
set -e
cd "$(dirname "$0")"

# Derive the Dropbox root from THIS script's own location instead of hardcoding
# it. The source tree lives at "<root>/BuddysCodexApps/Phantom App/PhantomControl",
# so the root is three levels up. This survives a new laptop (different username,
# and Dropbox now mounts under ~/Library/CloudStorage/Dropbox-… rather than the
# old "~/Buddy Bleckley Photo Dropbox" layout) with no edit.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REL="$ROOT/Phantom Control Beta Releases"
if [ ! -d "$REL" ]; then
    echo "ERROR: can't find the Beta Releases folder at:" >&2
    echo "  $REL" >&2
    echo "Expected this script to live in <dropbox>/daniel bleckley/BuddysCodexApps/Phantom App/PhantomControl." >&2
    echo "Aborting before the build so the build number isn't burned." >&2
    exit 1
fi
# Find the "Latest"/"Previous" folders by name so a manual rename (e.g. adding a
# "Phantom Control" prefix so the shared link reads clearly) doesn't make us
# publish into a stale hardcoded path and create a duplicate. Match any sibling
# folder with "latest"/"previous" in its name; else default to branded names.
LATEST="$(ls -d "$REL"/*[Ll]atest* 2>/dev/null | head -1)"
[ -z "$LATEST" ] && LATEST="$REL/Phantom Control Latest Version"
PREV="$(ls -d "$REL"/*[Pp]revious* 2>/dev/null | head -1)"
[ -z "$PREV" ] && PREV="$REL/Phantom Control Previous Versions"
mkdir -p "$LATEST" "$PREV"
echo "Publishing into: $LATEST"

# Shipped betas are UNIVERSAL (Apple Silicon + Intel) so older Mac Pros /
# Intel MacBooks in rental houses can run them too.
UNIVERSAL=1 ./build_app.sh
NEWVER="$(cat VERSION)"
OLDVER="$(cat "$LATEST/.pcversion" 2>/dev/null || echo '')"

# Archive the previous release when the marketing version rolls over.
if [ -n "$OLDVER" ] && [ "$OLDVER" != "$NEWVER" ]; then
    rm -f /tmp/pc_prev.zip
    ( cd "$REL" && COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr "$(basename "$LATEST")" /tmp/pc_prev.zip )
    mv -f /tmp/pc_prev.zip "$PREV/Phantom Control $OLDVER.zip"
    echo "Archived previous release ($OLDVER) -> Previous Versions/Phantom Control $OLDVER.zip"
fi

# Refresh the app + notes in the Latest folder (README + PDF are edited by hand).
# The install zip carries the version in its name (e.g. PhantomControl_v0.3.2.zip)
# so testers see at a glance which build they grabbed; the previous install zip
# (versioned or the legacy unversioned name) is cleared so only the current one
# remains.
ZIP="PhantomControl_v${NEWVER}.zip"
# COPYFILE_DISABLE / --norsrc / --noextattr matter here, not just on the archive
# step below. Without them ditto writes AppleDouble "._" companions for every
# extended attribute INSIDE the signed bundle (v0.4.2 shipped 23 entries for a
# 9-file bundle: ._Phantom Control, .__CodeSignature, ._CodeResources, …).
# Files inside a signed .app that aren't listed in CodeResources make
# `codesign --verify` fail after the tester unzips, which Gatekeeper reports as
# the app being damaged.
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "Phantom Control.app" /tmp/pc_app.zip
rm -f "$LATEST"/PhantomControl_v*.zip(N) "$LATEST/Phantom Control.zip"
cat /tmp/pc_app.zip > "$LATEST/$ZIP"
cp CHANGELOG.md "$LATEST/Release Notes.md"
printf "%s" "$NEWVER" > "$LATEST/.pcversion"
rm -f /tmp/pc_app.zip "$LATEST/.DS_Store" "$REL/.DS_Store"

# The 10G enabler kit. Shipped as its OWN zip rather than loose files, because a
# folder downloaded from a Dropbox share link arrives without executable bits —
# and a .command that isn't executable can't be double-clicked. A ditto archive
# carries the mode through Finder's unarchiver intact.
KITSRC="$(mktemp -d)"
KIT="$KITSRC/10G Downloads"
mkdir -p "$KIT"
cp -p "BetaKit/Enable 10G Downloads.command" "BetaKit/Disable 10G Downloads.command" "$KIT/"
cp -Rp BetaKit/ChmodBPF "$KIT/ChmodBPF"
chmod 755 "$KIT/Enable 10G Downloads.command" "$KIT/Disable 10G Downloads.command" "$KIT/ChmodBPF/ChmodBPF"
rm -f /tmp/pc_10g.zip
( cd "$KITSRC" && COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "10G Downloads" /tmp/pc_10g.zip )
cat /tmp/pc_10g.zip > "$LATEST/10G Downloads.zip"
rm -rf /tmp/pc_10g.zip "$KITSRC"
echo "  · bundled the 10G enabler kit"

# Integrity: the archive must be readable AND the bundle inside it must still
# pass its own signature check once expanded. A zip that unpacks cleanly but
# fails codesign is exactly the "app won't open" report we can't reproduce.
unzip -tq "$LATEST/$ZIP" >/dev/null || { echo "ERROR: $ZIP failed integrity test" >&2; exit 1; }
VERIFY_DIR="$(mktemp -d)"
ditto -x -k "$LATEST/$ZIP" "$VERIFY_DIR"
if codesign --verify --strict --deep "$VERIFY_DIR/Phantom Control.app" 2>/dev/null; then
    echo "Published $NEWVER to: $LATEST/$ZIP  (signature verified after round-trip)"
else
    echo "ERROR: the bundle inside $ZIP fails codesign after unzip — testers would see 'app is damaged'." >&2
    echo "       Not leaving a broken build in Latest Version." >&2
    rm -f "$LATEST/$ZIP"
    rm -rf "$VERIFY_DIR"
    exit 1
fi
rm -rf "$VERIFY_DIR"
