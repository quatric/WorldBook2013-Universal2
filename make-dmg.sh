#!/bin/zsh
# Build the Universal 2 "World Book DVD" disk image from MacKiev's 2013WorldBookMac.dmg.
#   ./make-dmg.sh <2013WorldBookMac.dmg> [version]
# Needs every app built first (xlate/build.sh, xlate/mkapp.sh, xlate/app.sh <id>,
# xlate/ppc/build.sh <id>; see README). Writes build/2013WorldBookMac_<version>.dmg.
#
# MacKiev's image holds a 32-bit installer that no current Mac runs. It is
# replaced by "2013 World Book Installer.pkg", which installs the translated
# apps (all Universal 2) in /Applications/2013 World Book and copies the
# encyclopedia's content from the image into the app (pkg/scripts/postinstall).
# The image keeps its volume name (World Book DVD, which the app looks for),
# content, background, window and icon layout and user guide; Registration on
# it is the translated one. Every bundle's version gets the -U2B suffix.
# The template is only read: changes go to a shadow file. Needs about 6 GB free.
set -e
cd "${0:A:h}"
TEMPLATE="${1:?usage: make-dmg.sh <2013WorldBookMac.dmg> [version]}"
VER="${2:-17.0.0-U2B}"
SUFFIX="-${VER#*-}"
PY="${PY:-.venv/bin/python}"
PKG_ID="io.github.quatric.worldbook2013-universal2"
PKG_VER="17.0.0.720.1"
SRC="game/2013 World Book"
APPS=("2013 World Book" "Notepad" "World Book Trivia Challenge" "World Book Distance Calculator"
	"World Book Dictionary" "What's New?" "World Book Registration"
	"Chart Wizard" "Quiz Wizard" "Report Wizard" "Timeline Wizard")
$PY -c "import ds_store" 2>/dev/null || { echo "$PY needs ds_store: $PY -m pip install -r requirements.txt" >&2; exit 1; }
for a in $APPS; do
	B="build/$a.app"
	E="$B/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$B/Contents/Info.plist" 2>/dev/null)"
	[[ "$(lipo -archs "$E" 2>/dev/null)" == "x86_64 arm64" ]] || { echo "$B is not built Universal 2 (see README)" >&2; exit 1; }
done

W="$PWD/build/dmg-work"
OUT="$PWD/build/2013WorldBookMac_${VER}.dmg"
rm -rf "$W" "$OUT"
I="$W/root/Applications/2013 World Book"
mkdir -p "$I" "$W/mnt"

# the install folder as MacKiev's installer laid it out, with the translated apps
for f in "Download" "Speech and VoiceOver.pdf"; do
	ditto "$SRC/$f" "$I/$f"
done
# the folder's custom icon (Icon\r, the icon in its resource fork); the payload
# extractor writes the name with \n
for f in $'Icon\r' $'Icon\n'; do
	if [[ -e "$SRC/$f" ]]; then
		ditto "$SRC/$f" "$I/"$'Icon\r'
		SetFile -a V "$I/"$'Icon\r'
		SetFile -a C "$I"
		break
	fi
done
for a in $APPS; do
	ditto "build/$a.app" "$I/$a.app"
done
# the test build links the disc's content into Resources; the installer copies it instead
rm -f "$I/2013 World Book.app/Contents/Resources/CD1" "$I/2013 World Book.app/Contents/Resources/CD2"
$PY tools/stamp_version.py "$SUFFIX" "$I" > "$W/stamped.txt"
for a in $APPS; do
	codesign --force --deep --sign - "$I/$a.app"
	codesign --verify --deep "$I/$a.app"   # not --strict: the wizards link to World Book outside their bundle
done

# the package: not relocatable (it always installs in /Applications)
pkgbuild --analyze --root "$W/root" "$W/component.plist" >/dev/null
$PY - "$W/component.plist" <<'EOF'
import plistlib, sys
p = sys.argv[1]
c = plistlib.load(open(p, "rb"))
for b in c:
    b["BundleIsRelocatable"] = False
    b["BundleOverwriteAction"] = "upgrade"
plistlib.dump(c, open(p, "wb"))
EOF
pkgbuild --root "$W/root" --install-location / --component-plist "$W/component.plist" \
	--scripts pkg/scripts --identifier "$PKG_ID" --version "$PKG_VER" "$W/wb.pkg"
cat > "$W/Distribution" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>2013 World Book $VER</title>
    <options customize="never" require-scripts="false" rootVolumeOnly="true" hostArchitectures="arm64,x86_64"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="11.0"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default">
            <line choice="$PKG_ID"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$PKG_ID" visible="false">
        <pkg-ref id="$PKG_ID"/>
    </choice>
    <pkg-ref id="$PKG_ID" version="$PKG_VER" onConclusion="none">wb.pkg</pkg-ref>
</installer-gui-script>
EOF
productbuild --distribution "$W/Distribution" --package-path "$W" "$W/installer.pkg"
rm -f "$W/wb.pkg"

# the image: the template with the installer and Registration replaced
hdiutil attach -nobrowse -noautoopen -noverify -shadow "$W/shadow" -mountpoint "$W/mnt" "$TEMPLATE" >/dev/null
trap 'hdiutil detach "$W/mnt" -quiet 2>/dev/null || true' EXIT
M="$W/mnt"
[[ -d "$M/2013CDs/CD1/INFO_DAT" ]] || { echo "$TEMPLATE is not the World Book DVD image" >&2; exit 1; }
rm -rf "$M/2013 World Book Installer.app" "$M/World Book Registration.app"
ditto "$W/installer.pkg" "$M/2013 World Book Installer.pkg"
ditto "$I/World Book Registration.app" "$M/World Book Registration.app"
$PY tools/dmg_layout.py "$M/.DS_Store" "2013 World Book Installer.app=>2013 World Book Installer.pkg"
sync
hdiutil detach "$M" -quiet
trap - EXIT
hdiutil convert "$TEMPLATE" -shadow "$W/shadow" -format UDZO -o "$OUT"
rm -rf "$W"
hdiutil verify "$OUT" >/dev/null
echo "built $OUT"
