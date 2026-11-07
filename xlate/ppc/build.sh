#!/bin/sh
# Translate one of the World Book wizards (PowerPC CFM applications) into
# "build/<name>.app".
# Usage: xlate/ppc/build.sh <chart|quiz|report|timeline> [lift]
set -e
cd "$(dirname "$0")/../.."
CC="clang -arch arm64 -mmacosx-version-min=11.0"
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
find $OUT/x -name '*.c' | while read c; do
	o=$c.o
	if [ ! -f $o ] || [ $c -nt $o ] || [ xlate/ppc/rt/ppccode.h -nt $o ] || [ xlate/ppc/rt/ppc.h -nt $o ]; then echo $c; fi
done | xargs -P 10 -I{} sh -c "$CC -O1 -w -fno-strict-aliasing -Ixlate/ppc/rt -c {} -o {}.o"
[ -f $OUT/x/blob.S.o ] && [ $OUT/x/blob.S.o -nt $OUT/x/code.bin ] || $CC -c $OUT/x/blob.S -o $OUT/x/blob.S.o
mkdir -p build/ppc/rt
for f in xlate/ppc/rt/*.m xlate/ppc/rt/*.c; do
	o=build/ppc/rt/$(basename $f).o
	if [ ! -f $o ] || [ $f -nt $o ] || [ -n "$(find xlate/ppc/rt -name '*.h' -newer $o)" ]; then
		echo "cc $f"
		ARC=-fno-objc-arc
		case $(basename $f) in ae.m|nav.m) ARC=-fobjc-arc ;; esac
		$CC -O1 -g -Wall -Wno-unused-function -Wno-deprecated-declarations $ARC -fno-strict-aliasing -Ixlate/ppc/rt -c $f -o $o
	fi
done
EXE=$(echo "$NAME" | tr -d ' ')
$CC -o "$OUT/$EXE" build/ppc/rt/*.o $OUT/x/*.o \
	-framework AppKit -framework Foundation -framework Carbon -framework CoreText -framework ImageIO \
	-framework AudioToolbox -framework AVFoundation -framework QuartzCore -framework PDFKit -Wl,-w

# the bundle: the translated executable, the original's resource fork, an icon
APP="build/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
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
