#!/bin/sh
# Runs the built app with the test driver (tools/driver.m) doing the steps given
# as arguments (or on stdin), then quits it and prints the runtime's log.
# usage: [APP=build/X.app] drive.sh <seconds to run> 'wait 8; windows; shot /tmp/a.png'
cd "$(dirname "$0")/.."
# APP picks another translated bundle (default: the encyclopedia);
# ARCH=x86_64 runs the Intel slice (under Rosetta on Apple silicon)
APP=${APP:-"build/2013 World Book.app"}
EXE="$APP/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")"
[ build/driver.dylib -nt tools/driver.m ] || clang -arch arm64 -arch x86_64 -dynamiclib -fobjc-arc -framework Cocoa -framework AVFoundation -framework CoreMedia -framework WebKit -o build/driver.dylib tools/driver.m
STEPS=${2:-$(cat)}
# arch -e: SIP strips DYLD_* from the environment of /usr/bin/arch itself
arch -${ARCH:-arm64} -e WB_DRIVE="$STEPS" -e DYLD_INSERT_LIBRARIES="$PWD/build/driver.dylib" -e XL_VERBOSE=${XL_VERBOSE:-0} -e XL_HANDLE_TRACE=${XL_HANDLE_TRACE:-0} ${XL_HELP_DRYRUN:+-e XL_HELP_DRYRUN=1} "$EXE" -ApplePersistenceIgnoreState YES $DRIVE_ARGS > build/run.log 2>&1 &
PID=$!
T=0
while [ $T -lt ${1:-20} ] && kill -0 $PID 2>/dev/null; do sleep 1; T=$((T + 1)); done
kill -0 $PID 2>/dev/null || echo "== app exited"
kill $PID 2>/dev/null; sleep 1; kill -9 $PID 2>/dev/null
grep -v "copied by value\|missing data symbol\|AGX\|^$" build/run.log | head -${M:-80}
