#!/bin/sh
# Translate one of the companion apps installed next to 2013 World Book
# (Notepad, Trivia Challenge, the Atlas) into "build/<name>.app".
# Usage: xlate/app.sh <notepad|trivia|atlas|dictionary|whatsnew> [lift]
#   lift: thin the i386 slices and run the lifter again
# The runtime objects are shared with xlate/build.sh (build/rt).
set -e
cd "$(dirname "$0")/.."
PY=${PY:-python3}   # needs capstone
CC="clang -arch arm64 -mmacosx-version-min=11.0"
ID=$1
case "$ID" in
notepad) NAME="Notepad" ;;
trivia) NAME="World Book Trivia Challenge" ;;
atlas) NAME="World Book Distance Calculator" ;;
dictionary) NAME="World Book Dictionary" ;;
whatsnew) NAME="What's New?" ;;
*) echo "usage: $0 notepad|trivia|atlas|dictionary|whatsnew [lift]" >&2; exit 1 ;;
esac
SRC="game/2013 World Book/$NAME.app"
EXE=$(plutil -extract CFBundleExecutable raw "$SRC/Contents/Info.plist")
AN=analysis/$ID
OUT=build/$ID

# the images: the executable (id "exe") and every private framework (id: its name, lower case)
images() {
	echo "exe|$SRC/Contents/MacOS/$EXE"
	for f in "$SRC"/Contents/Frameworks/*.framework; do
		[ -d "$f" ] || continue
		n=$(basename "$f" .framework)
		echo "$(echo $n | tr A-Z a-z)|$f/Versions/Current/$n"
	done
}

if [ "$2" = lift ] || [ ! -d $OUT/x ]; then
	rm -rf $AN $OUT/x
	mkdir -p $AN $OUT/x
	images | while IFS='|' read id bin; do
		lipo -thin i386 "$bin" -output $AN/$id-i386 2>/dev/null || cp "$bin" $AN/$id-i386
	done
	images | while IFS='|' read id bin; do
		echo "lift $id"
		$PY -I xlate/lift32.py $AN/$id-i386 $id $OUT/x/$id $AN/*-i386
	done
fi

find $OUT/x -name '*.c' | while read c; do
	o=$c.o
	if [ ! -f $o ] || [ $c -nt $o ] || [ xlate/rt/xlcode.h -nt $o ] || [ xlate/rt/xl.h -nt $o ]; then echo $c; fi
done | xargs -P 10 -I{} sh -c "$CC -O1 -w -fno-strict-aliasing -Ixlate/rt -c {} -o {}.o"
for d in $OUT/x/*; do
	[ -f $d/blob.S.o ] && [ $d/blob.S.o -nt $d/image.bin ] || $CC -c $d/blob.S -o $d/blob.S.o
done
mkdir -p build/rt
for f in xlate/rt/*.m xlate/rt/*.c; do
	o=build/rt/$(basename $f).o
	if [ ! -f $o ] || [ $f -nt $o ] || [ -n "$(find xlate/rt -name '*.h' -newer $o)" ]; then
		$CC -O1 -g -w -fno-objc-arc -fno-strict-aliasing -Ixlate/rt -c $f -o $o
	fi
done
$CC -o "$OUT/$EXE" build/rt/*.o $OUT/x/*/*.o -lffi \
	-framework AppKit -framework Foundation -framework Carbon -framework OpenGL -framework WebKit \
	-framework AudioToolbox -framework AVFoundation -framework AudioUnit -framework CoreAudio -framework Security \
	-framework SystemConfiguration -framework IOKit -framework ApplicationServices -framework Accelerate \
	-framework CoreServices -framework QuartzCore -lsqlite3 -lz \
	-Wl,-w

# the bundle: the original's resources around the translated executable
APP="build/$NAME.app"
mkdir -p "$APP"
rsync -a --exclude "/Contents/MacOS/$EXE" "$SRC/" "$APP/"
plutil -replace NSRequiresAquaSystemAppearance -bool YES "$APP/Contents/Info.plist"
plutil -remove LSArchitecturePriority "$APP/Contents/Info.plist" 2>/dev/null || true
plutil -remove LSRequiresNativeExecution "$APP/Contents/Info.plist" 2>/dev/null || true
rm -f "$APP/Contents/MacOS/$EXE"
cp "$OUT/$EXE" "$APP/Contents/MacOS/$EXE"
echo "$APP"
