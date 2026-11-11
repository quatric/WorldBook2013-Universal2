#!/bin/sh
# Translate one of the companion apps installed next to 2013 World Book
# (Notepad, Trivia Challenge, the Atlas, the Dictionary, What's New?, Registration) into "build/<name>.app".
# Usage: xlate/app.sh <notepad|trivia|atlas|dictionary|whatsnew|registration> [lift]
#   lift: thin the i386 slices and run the lifter again
# The runtime objects are shared with xlate/build.sh (build/rt/<arch>).
# Builds every architecture in $ARCHS (default: arm64 x86_64) and merges them.
set -e
cd "$(dirname "$0")/.."
PY=${PY:-$([ -x .venv/bin/python ] && echo .venv/bin/python || echo python3)}   # needs capstone (requirements.txt)
ARCHS=${ARCHS:-"arm64 x86_64"}
. xlate/arch.sh
ID=$1
case "$ID" in
notepad) NAME="Notepad" ;;
trivia) NAME="World Book Trivia Challenge" ;;
atlas) NAME="World Book Distance Calculator" ;;
dictionary) NAME="World Book Dictionary" ;;
whatsnew) NAME="What's New?" ;;
registration) NAME="World Book Registration" ;;
*) echo "usage: $0 notepad|trivia|atlas|dictionary|whatsnew|registration [lift]" >&2; exit 1 ;;
esac
SRC="game/2013 World Book/$NAME.app"
EXE=$(plutil -extract CFBundleExecutable raw "$SRC/Contents/Info.plist")
AN=analysis/$ID
OUT=build/$ID

# the images: the executable (id "exe"), every private framework and every
# plug-in the app loads with NSBundle (id: its name, lower case). A plug-in has
# no install name, so it gets its path in the bundle (xlate/rt/appkit.m answers
# NSBundle for it).
images() {
	echo "exe|$SRC/Contents/MacOS/$EXE|"
	for f in "$SRC"/Contents/Frameworks/*.framework; do
		[ -d "$f" ] || continue
		n=$(basename "$f" .framework)
		echo "$(echo $n | tr A-Z a-z)|$f/Versions/Current/$n|"
	done
	for f in "$SRC"/Contents/PlugIns/*.plugin; do
		[ -d "$f" ] || continue
		n=$(plutil -extract CFBundleExecutable raw "$f/Contents/Info.plist")
		echo "$(echo $n | tr A-Z a-z)|$f/Contents/MacOS/$n|@executable_path/../PlugIns/$(basename "$f")/Contents/MacOS/$n"
	done
}

if [ "$2" = lift ] || [ ! -d $OUT/x ]; then
	rm -rf $AN $OUT/x
	mkdir -p $AN $OUT/x
	images | while IFS='|' read id bin inst; do
		lipo -thin i386 "$bin" -output $AN/$id-i386 2>/dev/null || cp "$bin" $AN/$id-i386
	done
	images | while IFS='|' read id bin inst; do
		echo "lift $id"
		XL_INSTALL_NAME="$inst" $PY -I xlate/lift32.py $AN/$id-i386 $id $OUT/x/$id $AN/*-i386
	done
fi

for ARCH in $ARCHS; do
	CC="clang -arch $ARCH -mmacosx-version-min=11.0"
	compile_lifted $OUT/x xlate/rt xlate/rt/xlcode.h xlate/rt/xl.h
	for d in $OUT/x/*; do
		[ -f $d/blob.S.$ARCH.o ] && [ $d/blob.S.$ARCH.o -nt $d/image.bin ] || $CC -c $d/blob.S -o $d/blob.S.$ARCH.o
	done
	compile_rt xlate/rt build/rt/$ARCH
	$CC -o "$OUT/$EXE.$ARCH" build/rt/$ARCH/*.o $OUT/x/*/*.$ARCH.o -lffi $XL_LIBS -Wl,-w
done
merge "$OUT/$EXE"

# the bundle: the original's resources around the translated executable
APP="build/$NAME.app"
mkdir -p "$APP"
rsync -a --exclude "/Contents/MacOS/$EXE" "$SRC/" "$APP/"
plutil -replace NSRequiresAquaSystemAppearance -bool YES "$APP/Contents/Info.plist"
plutil -remove LSArchitecturePriority "$APP/Contents/Info.plist" 2>/dev/null || true
plutil -remove LSRequiresNativeExecution "$APP/Contents/Info.plist" 2>/dev/null || true
rm -f "$APP/Contents/MacOS/$EXE"
cp "$OUT/$EXE" "$APP/Contents/MacOS/$EXE"
# the original 32-bit frameworks and plug-ins, translated above, become empty Universal 2 stubs
sh xlate/stub_i386.sh "$APP" > /dev/null
echo "$APP"
