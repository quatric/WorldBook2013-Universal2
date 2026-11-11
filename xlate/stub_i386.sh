#!/bin/sh
# Replaces the original 32-bit binaries left in a built bundle (private
# frameworks, plug-ins, preference panes) with empty Universal 2 ones.
# Their code is translated into the app's executable and never loaded, but
# the files must stay: NSBundle reports no executablePath for a bundle
# without one, and the runtime knows its translated bundles by that path
# (xlate/rt/appkit.m). A framework's stub keeps its install name.
# usage: xlate/stub_i386.sh <app bundle>
set -e
APP="$1"
T="$(cd "$(dirname "$0")/.." && pwd)/build/stub-tmp.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
echo 'static int xl_stub __attribute__((used));' > "$T/stub.c"
find -P "$APP" -type f -not -path "*/Contents/Resources/CD[12]/*" -size +1k -print | while IFS= read -r f; do
	file -b "$f" | grep -q '^Mach-O' || continue
	a=$(lipo -archs "$f" 2>/dev/null || true)
	[ "$a" = "x86_64 arm64" ] && continue
	if file -b "$f" | grep -q 'dynamically linked shared library'; then
		name=$(otool -D "$f" | sed -n 2p)
		clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -dynamiclib -install_name "$name" -o "$T/out" "$T/stub.c"
	elif file -b "$f" | grep -q 'bundle'; then
		clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -bundle -o "$T/out" "$T/stub.c"
	else
		continue    # an executable is the translated one, already Universal 2
	fi
	rm -f "$f"
	cp "$T/out" "$f"
	echo "stub ($a): ${f#$APP/}"
done
