#!/bin/sh
# Assemble "build/2013 World Book.app" from the original bundle and the translated executable.
set -e
cd "$(dirname "$0")/.."
SRC="game/2013 World Book/2013 World Book.app"
APP="build/2013 World Book.app"
# keep the bundle in step with the extracted original (symlinks included)
mkdir -p "$APP"
rsync -a --exclude "/Contents/MacOS/2013 World Book" "$SRC/" "$APP/"
# a new file each time: the kernel caches code signatures per file, and an
# executable overwritten in place gets killed at launch; the linker's ad-hoc
# signature is kept (the bundle itself carries the original's resources)
rm -f "$APP/Contents/MacOS/2013 World Book"
cp build/WorldBook "$APP/Contents/MacOS/2013 World Book"
echo "$APP"
