#!/bin/zsh
# Build the Universal 2 "World Book DVD" disk image with the whole 2013 World Book
# folder on it, from MacKiev's 2013WorldBookMac.dmg.
#   ./make-dmg-folder.sh <2013WorldBookMac.dmg> [version]
# Needs every app built first (see README). Writes build/2013WorldBookMac_<version>.dmg.
#
# Unlike make-dmg.sh, which replaces MacKiev's installer with an installer
# package that copies the encyclopedia's content from the image into the app,
# this image holds the finished "2013 World Book" folder (the 11 translated
# apps, Download, the speech guide, and the content in the app's Resources), to
# be dragged into Applications. The content is in the folder, so the image's own
# copy (2013CDs) is left out. The volume name (World Book DVD), background, window
# and icon layout, volume icon and user guide are MacKiev's; the folder takes the
# installer's place in the layout. Every bundle's version gets the version's suffix (-U2D).
# The template is only read. Needs about 12 GB free.
set -e
cd "${0:A:h}"
TEMPLATE="${1:?usage: make-dmg-folder.sh <2013WorldBookMac.dmg> [version]}"
VER="${2:-17.0.0-U2D}"
SUFFIX="-${VER#*-}"
PY="${PY:-.venv/bin/python}"
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
V="$W/vol"                      # what the image will hold
I="$V/2013 World Book"          # the folder
T="$W/template"
mkdir -p "$I" "$T"
hdiutil attach -nobrowse -noautoopen -readonly -noverify -mountpoint "$T" "$TEMPLATE" >/dev/null
trap 'hdiutil detach "$T" -quiet 2>/dev/null || true' EXIT
[[ -d "$T/2013CDs/CD1/INFO_DAT" ]] || { echo "$TEMPLATE is not the World Book DVD image" >&2; exit 1; }

# the folder as MacKiev's installer laid it out, with the translated apps
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
# the test build links the disc's content into Resources; here it is copied in,
# without the disc's Finder info, which codesign refuses to seal
RES="$I/2013 World Book.app/Contents/Resources"
rm -f "$RES/CD1" "$RES/CD2"
for cd in CD1 CD2; do
	ditto --norsrc --noextattr --noqtn "$T/2013CDs/$cd" "$RES/$cd"
done
chmod -R a+rX "$RES/CD1" "$RES/CD2"
xattr -cr "$RES/CD1" "$RES/CD2" 2>/dev/null || true
$PY tools/stamp_version.py "$SUFFIX" "$I" > "$W/stamped.txt"
for a in $APPS; do
	codesign --force --deep --sign - "$I/$a.app"
	codesign --verify --deep "$I/$a.app"   # not --strict: the wizards link to World Book outside their bundle
done

# the rest of the image as MacKiev made it: volume icon, background, user guide,
# the Finder's window and icon layout; Registration is the translated one
for f in .VolumeIcon.icns .DS_Store CD_Window-1.tiff "Desktop DB" "Desktop DF" "World Book User Guide.pdf"; do
	ditto "$T/$f" "$V/$f"
done
ditto "$I/World Book Registration.app" "$V/World Book Registration.app"
[[ -e "$V/.VolumeIcon.icns" ]] && SetFile -a C "$V"
$PY tools/dmg_layout.py "$V/.DS_Store" "2013 World Book Installer.app=>2013 World Book"
hdiutil detach "$T" -quiet
trap - EXIT

hdiutil create -srcfolder "$V" -volname "World Book DVD" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov -o "$OUT"
rm -rf "$W"
hdiutil verify "$OUT" >/dev/null
echo "built $OUT"
