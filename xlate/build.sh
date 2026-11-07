#!/bin/sh
# Compile the lifted images and the runtime for each architecture in $ARCHS
# (default: arm64 x86_64), link, and merge into the Universal 2 build/WorldBook.
# Usage: xlate/build.sh [lift]   (lift: re-run the lifter first)
set -e
cd "$(dirname "$0")/.."
PY=${PY:-$([ -x .venv/bin/python ] && echo .venv/bin/python || echo python3)}   # needs capstone (requirements.txt)
ARCHS=${ARCHS:-"arm64 x86_64"}
. xlate/arch.sh
if [ "$1" = lift ]; then
	grep -v '^#' xlate/images.txt | while read f id inst; do
		# bundles (plug-ins, preference panes) have no install name of their own
		[ -n "$f" ] && XL_INSTALL_NAME=$([ "$inst" = exe ] || echo "$inst") $PY -I xlate/lift32.py analysis/$f $id build/x/$id analysis/*-i386
	done
fi
for ARCH in $ARCHS; do
	CC="clang -arch $ARCH -mmacosx-version-min=11.0"
	compile_lifted build/x xlate/rt xlate/rt/xlcode.h xlate/rt/xl.h
	for d in build/x/*; do
		[ -f $d/blob.S.$ARCH.o ] && [ $d/blob.S.$ARCH.o -nt $d/image.bin ] || $CC -c $d/blob.S -o $d/blob.S.$ARCH.o
	done
	compile_rt xlate/rt build/rt/$ARCH
	$CC -o build/WorldBook.$ARCH build/rt/$ARCH/*.o build/x/*/*.$ARCH.o -lffi $XL_LIBS -Wl,-w
done
merge build/WorldBook
echo built build/WorldBook: $(lipo -archs build/WorldBook)
