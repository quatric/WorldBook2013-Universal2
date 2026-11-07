#!/bin/sh
# Runs the built app with the test driver (tools/driver.m) doing the steps given
# as arguments (or on stdin), then quits it and prints the runtime's log.
# usage: drive.sh <seconds to run> 'wait 8; windows; shot /tmp/a.png'
cd "$(dirname "$0")/.."
APP="build/2013 World Book.app"
EXE="$APP/Contents/MacOS/2013 World Book"
[ build/driver.dylib -nt tools/driver.m ] || clang -dynamiclib -fobjc-arc -framework Cocoa -framework AVFoundation -framework CoreMedia -o build/driver.dylib tools/driver.m
STEPS=${2:-$(cat)}
WB_DRIVE="$STEPS" DYLD_INSERT_LIBRARIES="$PWD/build/driver.dylib" XL_VERBOSE=${XL_VERBOSE:-0} "$EXE" -ApplePersistenceIgnoreState YES > build/run.log 2>&1 &
PID=$!
T=0
while [ $T -lt ${1:-20} ] && kill -0 $PID 2>/dev/null; do sleep 1; T=$((T + 1)); done
kill -0 $PID 2>/dev/null || echo "== app exited"
kill $PID 2>/dev/null; sleep 1; kill -9 $PID 2>/dev/null
grep -v "copied by value\|missing data symbol\|AGX\|^$" build/run.log | head -${M:-80}
