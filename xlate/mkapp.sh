#!/bin/sh
# Assemble "build/2013 World Book.app" from the original bundle and the translated executable.
set -e
cd "$(dirname "$0")/.."
SRC="game/2013 World Book/2013 World Book.app"
APP="build/2013 World Book.app"
if [ ! -d "$APP" ]; then
	mkdir -p "$APP"
	rsync -a "$SRC/" "$APP/"
fi
cp build/WorldBook "$APP/Contents/MacOS/2013 World Book"
codesign -f -s - "$APP/Contents/MacOS/2013 World Book" 2>/dev/null || true
echo "$APP"
