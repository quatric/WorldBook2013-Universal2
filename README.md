# 2013 World Book — Universal 2

Runs Software MacKiev's 2013 World Book (17.0.0, build 720) and its companion
apps natively on current Macs, Apple silicon and Intel. The originals are
32-bit only (i386, some PowerPC), which no Mac has run since macOS 10.15.
Their code is statically translated to C and compiled into Universal 2
(arm64 + x86_64) executables. No Rosetta needed.

| App | Original | How |
| --- | --- | --- |
| 2013 World Book, Notepad, Trivia Challenge, Distance Calculator, Dictionary, What's New?, Registration | i386 Cocoa | `xlate/lift32.py`, runtime in `xlate/rt` |
| Chart, Quiz, Report and Timeline Wizard | PowerPC CFM (Carbon) | `xlate/ppc/liftppc.py`, runtime in `xlate/ppc/rt` |

`docs/design.md` describes the translation: the 32-bit guest memory window,
object handles, Objective-C 1 classes, and calls across the boundary.

## Build

Inputs (not in the repository): the installer payload extracted into `game/`
(`tools/unarch` + `tools/unzp.py`) and the thin i386 slices in `analysis/`
(see `xlate/images.txt`).

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
sh xlate/build.sh lift          # 2013 World Book: lift, then build -> build/WorldBook
sh xlate/mkapp.sh               # -> "build/2013 World Book.app"
for a in notepad trivia atlas dictionary whatsnew registration; do sh xlate/app.sh $a; done
for w in chart quiz report timeline; do sh xlate/ppc/build.sh $w; done
```

Every script builds both architectures and merges them with `lipo`. Set
`ARCHS=arm64` (or `x86_64`) for a quicker single-architecture build while
working on something.

## Test

```sh
sh xlate/drive.sh 60 'wait 25; key return; wait 10; shot /tmp/home.png'       # arm64
ARCH=x86_64 sh xlate/drive.sh 60 'wait 30; key return; wait 10; windows'      # Intel slice, under Rosetta
APP="build/Notepad.app" sh xlate/drive.sh 20 'wait 8; windows'
```

`tools/driver.m` (injected for test runs only) lists the steps it understands.
`WB_DVD=<mounted DVD>` before `xlate/mkapp.sh` links the disc's content into
the test app.

## Surf The Ages as plain HTML

`tools/surf_extract.py` unpacks the Surf The Ages feature (`Surf.book` in the
app's Resources) into a folder of pages, pictures and sounds that opens in a
web browser (`index.htm`). Links to World Book articles, which only the app
can show, become plain text.

```sh
python3 tools/surf_extract.py "game/2013 World Book/2013 World Book.app/Contents/Resources/Surf.book" "build/Surf The Ages"
```

## Disk image

`make-dmg.sh` builds `build/2013WorldBookMac_17.0.0-U2B.dmg` from MacKiev's
`2013WorldBookMac.dmg` (the "World Book DVD" image):

- MacKiev's installer is a 32-bit app, so it is replaced by
  `2013 World Book Installer.pkg`. The package installs the 11 translated apps
  in `/Applications/2013 World Book`, as the original installer laid them out,
  and its postinstall copies the encyclopedia's content (`2013CDs`, 4.3 GB)
  from the image into the app, like MacKiev's full install.
- Registration on the image is the translated one.
- Every bundle's version ends in `-U2B` (17.0.0-U2B for World Book).
  `CFBundleVersion` keeps its build number.
- The volume name (which the app looks for when its content is not
  installed), content, background, window and icon layout and user guide are
  MacKiev's.

```sh
./make-dmg.sh 2013WorldBookMac.dmg 17.0.0-U2B
```

The template is only read; changes go to a shadow file. It needs about 6 GB free.

## Known issues

- The apps are signed ad hoc, and the installer package is unsigned. The first
  time, macOS asks before opening the installer: Control-click it and choose
  Open, or allow it in System Settings > Privacy & Security.
- QuickTime movies (QTKit `QTMovie`) are not available, so video clips in the
  articles and the home screen do not play. Pictures and sound do.
- The screen saver, Dashboard widgets and Spotlight importer that MacKiev's
  installer also put in place are 32-bit plug-ins for hosts that no longer
  load them, and are not installed.
- What's Online's Update Now reaches MacKiev's updating service
  (worldbook.softwaremackiev.com), which no longer accepts the 2013 edition,
  so it ends with "Updating was not successful". The other What's Online
  sections that use the installed content are not affected.
- Help Viewer is gone from macOS 27 (Tips shows these help books blank), so
  there Help menus, help buttons and What's New? open the help pages in your
  web browser instead.
