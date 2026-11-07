#!/bin/sh
# Compile the lifted images and the runtime, link the arm64 executable.
# Usage: xlate/build.sh [lift]   (lift: re-run the lifter first)
set -e
cd "$(dirname "$0")/.."
PY=${PY:-python3}   # needs capstone
CC="clang -arch arm64 -mmacosx-version-min=11.0"
if [ "$1" = lift ]; then
	grep -v '^#' xlate/images.txt | while read f id inst; do
		[ -n "$f" ] && $PY -I xlate/lift32.py analysis/$f $id build/x/$id analysis/*-i386
	done
fi
# generated code: compile files whose object is older than the source or the headers
find build/x -name '*.c' | while read c; do
	o=$c.o
	if [ ! -f $o ] || [ $c -nt $o ] || [ xlate/rt/xlcode.h -nt $o ] || [ xlate/rt/xl.h -nt $o ]; then echo $c; fi
done | xargs -P 10 -I{} sh -c "$CC -O1 -w -fno-strict-aliasing -Ixlate/rt -c {} -o {}.o"
for d in build/x/*; do
	[ -f $d/blob.S.o ] && [ $d/blob.S.o -nt $d/image.bin ] || $CC -c $d/blob.S -o $d/blob.S.o
done
mkdir -p build/rt
for f in xlate/rt/*.m xlate/rt/*.c; do
	o=build/rt/$(basename $f).o
	if [ ! -f $o ] || [ $f -nt $o ] || [ -n "$(find xlate/rt -name '*.h' -newer $o)" ]; then
		$CC -O1 -g -w -fno-objc-arc -fno-strict-aliasing -Ixlate/rt -c $f -o $o
	fi
done
$CC -o build/WorldBook build/rt/*.o build/x/*/*.o -lffi \
	-framework AppKit -framework Foundation -framework Carbon -framework OpenGL -framework WebKit \
	-framework AudioToolbox -framework AudioUnit -framework CoreAudio -framework Security \
	-framework SystemConfiguration -framework IOKit -framework ApplicationServices -framework Accelerate \
	-framework CoreServices -framework QuartzCore -lsqlite3 -lz \
	-Wl,-w
echo built build/WorldBook
