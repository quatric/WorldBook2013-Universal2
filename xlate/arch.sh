# Shared by xlate/build.sh, xlate/app.sh and xlate/ppc/build.sh (sourced).
# Objects are per architecture: <file>.c.<arch>.o next to generated code,
# <dir>/<arch>/<file>.o for the runtimes. Callers set ARCHS, ARCH and CC.

XL_LIBS="-framework AppKit -framework Foundation -framework Carbon -framework OpenGL -framework WebKit \
	-framework AudioToolbox -framework AVFoundation -framework AudioUnit -framework CoreAudio -framework Security \
	-framework SystemConfiguration -framework IOKit -framework ApplicationServices -framework Accelerate \
	-framework CoreServices -framework QuartzCore -framework ImageIO -framework PreferencePanes -framework UniformTypeIdentifiers -lsqlite3 -lz"

# compile_lifted <dir> <include dir> <header>...: generated C whose object
# is older than the source or any of the headers
compile_lifted() {
	dir=$1 inc=$2
	shift 2
	find $dir -name '*.c' | while read c; do
		o=$c.$ARCH.o
		stale=
		[ -f $o ] && [ ! $c -nt $o ] || stale=1
		for h in "$@"; do [ $h -nt $o ] && stale=1; done
		[ -n "$stale" ] && echo $c
	done | xargs -P 10 -I{} sh -c "$CC -O1 -w -fno-strict-aliasing -I$inc -c {} -o {}.$ARCH.o"
}

# compile_rt <source dir> <object dir> [extra flags]
compile_rt() {
	src=$1 obj=$2
	shift 2
	mkdir -p $obj
	for f in $src/*.m $src/*.c; do
		[ -f "$f" ] || continue
		o=$obj/$(basename $f).o
		if [ ! -f $o ] || [ $f -nt $o ] || [ -n "$(find $src -name '*.h' -newer $o)" ]; then
			arc=-fno-objc-arc
			case " $XL_ARC_FILES " in *" $(basename $f) "*) arc=-fobjc-arc ;; esac
			$CC -O1 -g -w $arc -fno-strict-aliasing -I$src "$@" -c $f -o $o
		fi
	done
}

# merge <output>: lipo <output>.<arch> for every arch in $ARCHS
merge() {
	out=$1
	set --
	for a in $ARCHS; do set -- "$@" "$out.$a"; done
	rm -f "$out"
	lipo -create "$@" -output "$out"
}
