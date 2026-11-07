#!/bin/sh
# Translate one of the World Book wizards (PowerPC CFM applications) into
# "build/<name>.app".
# Usage: xlate/ppc/build.sh <chart|quiz|report|timeline> [lift]
# Builds every architecture in $ARCHS (default: arm64 x86_64) and merges them.
set -e
cd "$(dirname "$0")/../.."
ARCHS=${ARCHS:-"arm64 x86_64"}
. xlate/arch.sh
ID=$1
case "$ID" in
chart) NAME="Chart Wizard" ;;
quiz) NAME="Quiz Wizard" ;;
report) NAME="Report Wizard" ;;
timeline) NAME="Timeline Wizard" ;;
*) echo "usage: $0 chart|quiz|report|timeline [lift]" >&2; exit 1 ;;
esac
SRC="game/Wizards/$NAME"
OUT=build/ppc/$ID
if [ "$2" = lift ] || [ ! -d $OUT/x ]; then
	mkdir -p $OUT/x
	python3 -I xlate/ppc/liftppc.py "$SRC" $OUT/x
fi
EXE=$(echo "$NAME" | tr -d ' ')
for ARCH in $ARCHS; do
	CC="clang -arch $ARCH -mmacosx-version-min=11.0"
	compile_lifted $OUT/x xlate/ppc/rt xlate/ppc/rt/ppccode.h xlate/ppc/rt/ppc.h
	[ -f $OUT/x/blob.S.$ARCH.o ] && [ $OUT/x/blob.S.$ARCH.o -nt $OUT/x/code.bin ] || $CC -c $OUT/x/blob.S -o $OUT/x/blob.S.$ARCH.o
	XL_ARC_FILES="ae.m nav.m" compile_rt xlate/ppc/rt build/ppc/rt/$ARCH
	$CC -o "$OUT/$EXE.$ARCH" build/ppc/rt/$ARCH/*.o $OUT/x/*.$ARCH.o \
		-framework AppKit -framework Foundation -framework Carbon -framework CoreText -framework ImageIO \
		-framework AudioToolbox -framework AVFoundation -framework QuartzCore -framework PDFKit -Wl,-w
done
merge "$OUT/$EXE"

# the bundle: the translated executable, the original's resource fork, an icon
APP="build/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
rm -f "$APP/Contents/MacOS/$EXE"   # a new file: the kernel caches signatures per file
cp "$OUT/$EXE" "$APP/Contents/MacOS/$EXE"
cp "$SRC/..namedfork/rsrc" "$APP/Contents/Resources/Application.rsrc"
python3 -I xlate/ppc/mkinfo.py "$SRC" "$EXE" "$NAME" "$APP"
# the shared wizard data, and World Book itself for "Look it up" (installed beside the wizards)
rm -rf "$APP/Contents/Resources/.World Book.wz"
cp -R "game/Wizards/.World Book.wz" "$APP/Contents/Resources/.World Book.wz"
ln -sfh "../../../2013 World Book.app" "$APP/Contents/Resources/.World Book.ln"
# the Timeline Wizard also reads two of World Book's own tables from that folder
for f in DROPWORD.LST TLINETBL.TXT; do
	cp "game/2013 World Book/2013 World Book.app/Contents/Resources/$f" "$APP/Contents/Resources/.World Book.wz/Contents/MacOS/WB Data/$f"
done
echo "$APP"
