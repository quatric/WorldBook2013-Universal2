#!/bin/sh
# Assemble "build/2013 World Book.app" from the original bundle and the translated executable.
set -e
cd "$(dirname "$0")/.."
SRC="game/2013 World Book/2013 World Book.app"
APP="build/2013 World Book.app"
# keep the bundle in step with the extracted original (symlinks included)
mkdir -p "$APP"
rsync -a --exclude "/Contents/MacOS/2013 World Book" "$SRC/" "$APP/"
# the original predates Dark Mode, which an executable linked against a
# current SDK would get
plutil -replace NSRequiresAquaSystemAppearance -bool YES "$APP/Contents/Info.plist"
# a new file each time: the kernel caches code signatures per file, and an
# executable overwritten in place gets killed at launch; the linker's ad-hoc
# signature is kept (the bundle itself carries the original's resources)
rm -f "$APP/Contents/MacOS/2013 World Book"
cp build/WorldBook "$APP/Contents/MacOS/2013 World Book"
# the original 32-bit frameworks and plug-ins, translated above, become empty Universal 2 stubs
sh xlate/stub_i386.sh "$APP" > /dev/null
# the DVD's content where a full install puts it (the app looks in its
# Resources before asking for the disc); WB_DVD is the mounted disc image
DVD=${WB_DVD:-"/Volumes/World Book DVD"}
for cd in CD1 CD2; do
	if [ -d "$DVD/2013CDs/$cd/INFO_DAT" ] && [ ! -e "$APP/Contents/Resources/$cd" ]; then
		ln -s "$DVD/2013CDs/$cd" "$APP/Contents/Resources/$cd"
	fi
done
echo "$APP"
